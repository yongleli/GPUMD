/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


#include "common.h"
#include "mic.cu" // static __device__ dev_apply_mic(...)
#include "eam_zhou_2004.h"



// References: 
// [1] X. W. Zhou, R. A. Johnson, and H. N. G. Wadley, PRB 69, 144113 (2004).


// best block size here: 64 or 128
#define BLOCK_SIZE_FORCE 64




// pair function (phi and phip have been intentionally halved here)
static __device__ void find_phi(EAM eam, real d12, real &phi, real &phip)
{
    real r_ratio = d12 / eam.re;
    
    // slow
    //real tmp1 = pow(r_ratio - eam.kappa, 20.0);
    //real tmp2 = pow(r_ratio - eam.lambda, 20.0);
    
    // much faster
    
    real tmp1 = (r_ratio - eam.kappa) * (r_ratio - eam.kappa); // 2
    tmp1 *= tmp1; // 4
    tmp1 *= tmp1 * tmp1 * tmp1 * tmp1; // 20
    real tmp2 = (r_ratio - eam.lambda) * (r_ratio - eam.lambda); // 2
    tmp2 *= tmp2; // 4
    tmp2 *= tmp2 * tmp2 * tmp2 * tmp2; // 20    
    
    
    real phi1 = HALF * eam.A * exp(-eam.alpha * (r_ratio - ONE)) / (ONE + tmp1);
    real phi2 = HALF * eam.B * exp( -eam.beta * (r_ratio - ONE)) / (ONE + tmp2);
    phi = phi1 - phi2;
    phip = (phi2/eam.re)*(eam.beta+20.0*tmp2/(r_ratio-eam.lambda)/(ONE+tmp2))
         - (phi1/eam.re)*(eam.alpha+20.0*tmp1/(r_ratio-eam.kappa)/(ONE+tmp1));
}


// density function f(r)
static __device__ void find_f(EAM eam, real d12, real &f)
{
    real r_ratio = d12 / eam.re;
    
    // slow
    //real tmp = pow(r_ratio - eam.lambda, 20.0);
    
    // much faster
    
    real tmp = (r_ratio - eam.lambda) * (r_ratio - eam.lambda); // 2
    tmp *= tmp; // 4
    tmp *= tmp * tmp * tmp * tmp; // 20  
    
    
    f = eam.fe * exp(-eam.beta * (r_ratio - ONE)) / (ONE + tmp);
}


// derivative of the density function f'(r)
static __device__ void find_fp(EAM eam, real d12, real &fp)
{
    real r_ratio = d12 / eam.re;
    
    // slow
    //real tmp = pow(r_ratio - eam.lambda, 20.0);
    
    // much faster  
    real tmp = (r_ratio - eam.lambda) * (r_ratio - eam.lambda); // 2
    tmp *= tmp; // 4
    tmp *= tmp * tmp * tmp * tmp; // 20  
    
    
    real f = eam.fe * exp(-eam.beta * (r_ratio - ONE)) / (ONE + tmp);
    fp = -(f/eam.re)*(eam.beta+20.0*tmp/(r_ratio-eam.lambda)/(ONE+tmp));
}


// embedding function
static __device__ void find_F(EAM eam, real rho, real &F, real &Fp)
{      
    if (rho < eam.rho_n)
    {
        real x = rho / eam.rho_n - ONE;
        F = ((eam.Fn3 * x + eam.Fn2) * x + eam.Fn1) * x + eam.Fn0;
        Fp = ((THREE * eam.Fn3 * x + TWO * eam.Fn2) * x + eam.Fn1) / eam.rho_n;
    }
    else if (rho < eam.rho_0)
    {
        real x = rho / eam.rho_e - ONE;
        F = ((eam.F3 * x + eam.F2) * x + eam.F1) * x + eam.F0;
        Fp = ((THREE * eam.F3 * x + TWO * eam.F2) * x + eam.F1) / eam.rho_e;
    }
    else
    {
        real x = rho / eam.rho_s;
        real x_eta = pow(x, eam.eta);
        F = eam.Fe * (ONE - eam.eta * log(x)) * x_eta;
        Fp = (eam.eta / rho) * (F - eam.Fe * x_eta);
    }
}


// Calculate the embedding energy and its derivative
template <int cal_p>
__global__ void find_force_eam_step1
(
    EAM eam, int N, int pbc_x, int pbc_y, int pbc_z, int* g_NN, int* g_NL,
#ifdef USE_LDG
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z,
    const real* __restrict__ g_box, 
#else
    real* g_x, real* g_y, real* g_z, real* g_box,
#endif
    real* g_Fp, real* g_pe 
)
{ 
    int n1 = blockIdx.x * blockDim.x + threadIdx.x; // particle index
    

    
    if (n1 < N)
    {
           
        real lx = LDG(g_box, 0);
        real ly = LDG(g_box, 1);
        real lz = LDG(g_box, 2);
    
        int NN = g_NN[n1];
           
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
          
        // Calculate the density
        real rho = ZERO;
        for (int i1 = 0; i1 < NN; ++i1)
        {      
            int n2 = g_NL[n1 + N * i1];
            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
            real d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12); 
            real rho12 = ZERO;
            find_f(eam, d12, rho12);
            rho += rho12;
        }
        
        // Calculate the embedding energy F and its derivative Fp
        real F, Fp;
        find_F(eam, rho, F, Fp);
        if (cal_p)
        {
            g_pe[n1] = F;
        }        
        g_Fp[n1] = Fp;   
    }
}


// Force evaluation kernel
template <int cal_p, int cal_j, int cal_q>
__global__ void find_force_eam_step2
(
    EAM eam, int N, int pbc_x, int pbc_y, int pbc_z, int *g_NN, int *g_NL,
#ifdef USE_LDG
    const real* __restrict__ g_Fp, 
    const real* __restrict__ g_x, 
    const real* __restrict__ g_y, 
    const real* __restrict__ g_z, 
    const real* __restrict__ g_vx, 
    const real* __restrict__ g_vy, 
    const real* __restrict__ g_vz,
    const real* __restrict__ g_box,
#else
    real *g_Fp, real* g_x, real* g_y, real* g_z, 
    real* g_vx, real* g_vy, real* g_vz, real* g_box,
#endif
    real *g_fx, real *g_fy, real *g_fz,
    real *g_sx, real *g_sy, real *g_sz, real *g_pe, 
    real *g_h, int *g_label, int *g_fv_index, real *g_fv 
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x;
    __shared__ real s_fx[BLOCK_SIZE_FORCE];
    __shared__ real s_fy[BLOCK_SIZE_FORCE];
    __shared__ real s_fz[BLOCK_SIZE_FORCE];

    // if cal_p, then s1~s4 = px, py, pz, U; if cal_j, then s1~s5 = j1~j5
    __shared__ real s1[BLOCK_SIZE_FORCE];
    __shared__ real s2[BLOCK_SIZE_FORCE];
    __shared__ real s3[BLOCK_SIZE_FORCE];
    __shared__ real s4[BLOCK_SIZE_FORCE];
    __shared__ real s5[BLOCK_SIZE_FORCE];

    s_fx[threadIdx.x] = ZERO; 
    s_fy[threadIdx.x] = ZERO; 
    s_fz[threadIdx.x] = ZERO;  

    s1[threadIdx.x] = ZERO; 
    s2[threadIdx.x] = ZERO; 
    s3[threadIdx.x] = ZERO;
    s4[threadIdx.x] = ZERO;
    s5[threadIdx.x] = ZERO;

    if (n1 < N)
    {
           
        real lx = LDG(g_box, 0);
        real ly = LDG(g_box, 1);
        real lz = LDG(g_box, 2);
    
        int NN = g_NN[n1];        
        real x1 = LDG(g_x, n1); 
        real y1 = LDG(g_y, n1); 
        real z1 = LDG(g_z, n1);
        real vx1 = LDG(g_vx, n1); 
        real vy1 = LDG(g_vy, n1); 
        real vz1 = LDG(g_vz, n1);
        real Fp1 = LDG(g_Fp, n1);

        for (int i1 = 0; i1 < NN; ++i1)
        {   
            int n2 = g_NL[n1 + N * i1];
            real Fp2 = LDG(g_Fp, n2);
            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(pbc_x, pbc_y, pbc_z, x12, y12, z12, lx, ly, lz);
            real d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
            
            real phi, phip, fp;
            find_phi(eam, d12, phi, phip);
            find_fp(eam, d12, fp);
            
            // slower:
            //real f12x =  (x12 / d12) * (phip + Fp1 * fp); 
            //real f12y =  (y12 / d12) * (phip + Fp1 * fp); 
            //real f12z =  (z12 / d12) * (phip + Fp1 * fp); 
            //real f21x = -(x12 / d12) * (phip + Fp2 * fp); 
            //real f21y = -(y12 / d12) * (phip + Fp2 * fp); 
            //real f21z = -(z12 / d12) * (phip + Fp2 * fp); 
            
            // faster:
            phip /= d12;
            fp   /= d12;
            real f12x =  x12 * (phip + Fp1 * fp); 
            real f12y =  y12 * (phip + Fp1 * fp); 
            real f12z =  z12 * (phip + Fp1 * fp); 
            real f21x = -x12 * (phip + Fp2 * fp); 
            real f21y = -y12 * (phip + Fp2 * fp); 
            real f21z = -z12 * (phip + Fp2 * fp); 
            
            if (cal_p) // accumulate potential energy
            {
                s4[threadIdx.x] += phi;
            }
 
            // per atom force
            s_fx[threadIdx.x] += f12x - f21x; 
            s_fy[threadIdx.x] += f12y - f21y; 
            s_fz[threadIdx.x] += f12z - f21z;  

            // per-atom stress
            if (cal_p)
            {
                s1[threadIdx.x] -= x12 * (f12x - f21x) * HALF; 
                s2[threadIdx.x] -= y12 * (f12y - f21y) * HALF; 
                s3[threadIdx.x] -= z12 * (f12z - f21z) * HALF;
            }

            // per-atom heat current
            if (cal_j)
            {
                s1[threadIdx.x] += (f21x * vx1 + f21y * vy1) * x12;  // x-in
                s2[threadIdx.x] += (f21z * vz1) * x12;               // x-out
                s3[threadIdx.x] += (f21x * vx1 + f21y * vy1) * y12;  // y-in
                s4[threadIdx.x] += (f21z * vz1) * y12;               // y-out
                s5[threadIdx.x] += (f21x*vx1+f21y*vy1+f21z*vz1)*z12; // z-all
            }
 
            // accumulate heat across some sections (for NEMD)
            if (cal_q)
            {
                int index_12 = g_fv_index[n1] * 12;
                if (index_12 >= 0 && g_fv_index[n1 + N] == n2)
                {
                    g_fv[index_12 + 0]  = f12x;
                    g_fv[index_12 + 1]  = f12y;
                    g_fv[index_12 + 2]  = f12z;
                    g_fv[index_12 + 3]  = f21x;
                    g_fv[index_12 + 4]  = f21y;
                    g_fv[index_12 + 5]  = f21z;
                    g_fv[index_12 + 6]  = vx1;
                    g_fv[index_12 + 7]  = vy1;
                    g_fv[index_12 + 8]  = vz1;
                    g_fv[index_12 + 9]  = LDG(g_vx, n2);
                    g_fv[index_12 + 10] = LDG(g_vy, n2);
                    g_fv[index_12 + 11] = LDG(g_vz, n2);
                }  
            }
            
        }

        // save force
        g_fx[n1] = s_fx[threadIdx.x]; 
        g_fy[n1] = s_fy[threadIdx.x]; 
        g_fz[n1] = s_fz[threadIdx.x];

        if (cal_p) // save stress and potential
        {
            g_sx[n1] = s1[threadIdx.x]; 
            g_sy[n1] = s2[threadIdx.x]; 
            g_sz[n1] = s3[threadIdx.x];
            g_pe[n1] += s4[threadIdx.x]; // g_pe has embedding energy in it
        }

        if (cal_j) // save heat current
        {
            g_h[n1 + 0 * N] = s1[threadIdx.x];
            g_h[n1 + 1 * N] = s2[threadIdx.x];
            g_h[n1 + 2 * N] = s3[threadIdx.x];
            g_h[n1 + 3 * N] = s4[threadIdx.x];
            g_h[n1 + 4 * N] = s5[threadIdx.x];
        }

    }
}   


// Force evaluation wrapper
void gpu_find_force_eam
(Parameters *para, Force_Model *force_model, GPU_Data *gpu_data)
{
    int N = para->N;
    int grid_size = (N - 1) / BLOCK_SIZE_FORCE + 1;
    int pbc_x = para->pbc_x;
    int pbc_y = para->pbc_y;
    int pbc_z = para->pbc_z;
#ifdef FIXED_NL
    int *NN = gpu_data->NN; 
    int *NL = gpu_data->NL;
#else
    int *NN = gpu_data->NN_local; 
    int *NL = gpu_data->NL_local;
#endif
    real *x = gpu_data->x; 
    real *y = gpu_data->y; 
    real *z = gpu_data->z;
    real *vx = gpu_data->vx; 
    real *vy = gpu_data->vy; 
    real *vz = gpu_data->vz;
    real *fx = gpu_data->fx; 
    real *fy = gpu_data->fy; 
    real *fz = gpu_data->fz;
    real *box_length = gpu_data->box_length;
    real *sx = gpu_data->virial_per_atom_x; 
    real *sy = gpu_data->virial_per_atom_y; 
    real *sz = gpu_data->virial_per_atom_z; 
    real *pe = gpu_data->potential_per_atom;
    real *h = gpu_data->heat_per_atom;   
    
    int *label = gpu_data->label;
    int *fv_index = gpu_data->fv_index;
    real *fv = gpu_data->fv;
    
    EAM eam = force_model->eam1;
    
    real *Fp;
    cudaMalloc((void**)&Fp, sizeof(real) * N); // to be improved
    
    if (para->hac.compute)
    {
        find_force_eam_step1<0><<<grid_size, BLOCK_SIZE_FORCE>>>
        (eam, N, pbc_x, pbc_y, pbc_z, NN, NL, x, y, z, box_length, Fp, pe);
        
        find_force_eam_step2<0, 1, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
        (
            eam, N, pbc_x, pbc_y, pbc_z, NN, NL, Fp, x, y, z, vx, vy, vz, 
            box_length, fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
        );
    }
    else if (para->shc.compute)
    {
        find_force_eam_step1<0><<<grid_size, BLOCK_SIZE_FORCE>>>
        (eam, N, pbc_x, pbc_y, pbc_z, NN, NL, x, y, z, box_length, Fp, pe);
        
        find_force_eam_step2<0, 0, 1><<<grid_size, BLOCK_SIZE_FORCE>>>
        (
            eam, N, pbc_x, pbc_y, pbc_z, NN, NL, Fp, x, y, z, vx, vy, vz, 
            box_length, fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
        );
    }
    else
    {
        find_force_eam_step1<1><<<grid_size, BLOCK_SIZE_FORCE>>>
        (eam, N, pbc_x, pbc_y, pbc_z, NN, NL, x, y, z, box_length, Fp, pe);
        
        find_force_eam_step2<1, 0, 0><<<grid_size, BLOCK_SIZE_FORCE>>>
        (
            eam, N, pbc_x, pbc_y, pbc_z, NN, NL, Fp, x, y, z, vx, vy, vz, 
            box_length, fx, fy, fz, sx, sy, sz, pe, h, label, fv_index, fv
        );
    }
    
    cudaFree(Fp); // to be improved
}


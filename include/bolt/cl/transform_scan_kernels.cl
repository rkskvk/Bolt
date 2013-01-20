/***************************************************************************
*   Copyright 2012 Advanced Micro Devices, Inc.                                     
*                                                                                    
*   Licensed under the Apache License, Version 2.0 (the "License");   
*   you may not use this file except in compliance with the License.                 
*   You may obtain a copy of the License at                                          
*                                                                                    
*       http://www.apache.org/licenses/LICENSE-2.0                      
*                                                                                    
*   Unless required by applicable law or agreed to in writing, software              
*   distributed under the License is distributed on an "AS IS" BASIS,              
*   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.         
*   See the License for the specific language governing permissions and              
*   limitations under the License.                                                   
***************************************************************************/
#pragma OPENCL EXTENSION cl_amd_printf : enable

/******************************************************************************
 *  Kernel 0
 *****************************************************************************/
//__attribute__((reqd_work_group_size(KERNEL0WORKGROUPSIZE,1,1)))
template< typename iType, typename oType, typename initType, typename UnaryFunction, typename BinaryFunction >
__kernel void perBlockTransformScan(
                global oType* output,
                global iType* input,
                initType init,
                const uint vecSize,
                local oType* lds,
                global UnaryFunction* unaryOp,
                global BinaryFunction* binaryOp,
                global oType* scanBuffer,
                int exclusive) // do exclusive scan ?
{
    size_t gloId = get_global_id( 0 );
    size_t groId = get_group_id( 0 );
    size_t locId = get_local_id( 0 );
    size_t wgSize = get_local_size( 0 );
    //printf("gid=%i, lTid=%i, gTid=%i\n", groId, locId, gloId);

    //  Abort threads that are passed the end of the input vector
    if (gloId >= vecSize) return; // on SI this doesn't mess-up barriers

    // if exclusive, load gloId=0 w/ identity, and all others shifted-1
    oType val;
    if (exclusive)
    {
        if (gloId > 0)
        { // thread>0
            iType inVal = input[gloId-1];
            val = (oType) (*unaryOp)(inVal);
            lds[ locId ] = val;
        }
        else
        { // thread=0
            val = init;
            lds[ locId ] = val;
        }
    }
    else
    {
        iType inVal = input[gloId];
        val = (oType) (*unaryOp)(inVal);
        lds[ locId ] = val;
    }

    //  Computes a scan within a workgroup
    oType sum = val;
    for( size_t offset = 1; offset < wgSize; offset *= 2 )
    {
        barrier( CLK_LOCAL_MEM_FENCE );
        if (locId >= offset)
        {
            oType y = lds[ locId - offset ];
            sum = (*binaryOp)( sum, y );
        }
        barrier( CLK_LOCAL_MEM_FENCE );
        lds[ locId ] = sum;
    }

    //  Each work item writes out its calculated scan result, relative to the beginning
    //  of each work group
    output[ gloId ] = sum;
    barrier( CLK_LOCAL_MEM_FENCE ); // needed for large data types
    if (locId == 0)
    {
        // last work-group can be wrong b/c ignored
        scanBuffer[ groId ] = lds[ wgSize-1 ];
    }
}


/******************************************************************************
 *  Kernel 1
 *****************************************************************************/
//__attribute__((reqd_work_group_size(KERNEL1WORKGROUPSIZE,1,1)))
template< typename Type, typename BinaryFunction >
__kernel void intraBlockInclusiveScan(
                global Type* postSumArray,
                global Type* preSumArray,
                const uint vecSize,
                local Type* lds,
                const uint workPerThread,
                global BinaryFunction* binaryOp
                )
{
    size_t groId = get_group_id( 0 );
    size_t gloId = get_global_id( 0 );
    size_t locId = get_local_id( 0 );
    size_t wgSize = get_local_size( 0 );
    uint mapId  = gloId * workPerThread;

    // do offset of zero manually
    uint offset;
    Type workSum;
    if (mapId < vecSize)
    {
        // accumulate zeroth value manually
        offset = 0;
        workSum = preSumArray[mapId+offset];
        postSumArray[ mapId + offset ] = workSum;

        //  Serial accumulation
        for( offset = offset+1; offset < workPerThread; offset += 1 )
        {
            if (mapId+offset<vecSize)
            {
                Type y = preSumArray[mapId+offset];
                workSum = (*binaryOp)( workSum, y );
                postSumArray[ mapId + offset ] = workSum;
            }
        }
    }
    barrier( CLK_LOCAL_MEM_FENCE );
    Type scanSum;
    offset = 1;
    // load LDS with register sums
    if (mapId < vecSize)
    {
        lds[ locId ] = workSum;
        barrier( CLK_LOCAL_MEM_FENCE );
    
        if (locId >= offset)
        { // thread > 0
            Type y = lds[ locId - offset ];
            Type y2 = lds[ locId ];
            scanSum = (*binaryOp)( y2, y );
            lds[ locId ] = scanSum;
        } else { // thread 0
            scanSum = workSum;
        }  
    }
    // scan in lds
    for( offset = offset*2; offset < wgSize; offset *= 2 )
    {
        barrier( CLK_LOCAL_MEM_FENCE );
        if (mapId < vecSize)
        {
            if (locId >= offset)
            {
                Type y = lds[ locId - offset ];
                scanSum = (*binaryOp)( scanSum, y );
                lds[ locId ] = scanSum;
            }
        }
    } // for offset
    barrier( CLK_LOCAL_MEM_FENCE );
    
    // write final scan from pre-scan and lds scan
    for( offset = 0; offset < workPerThread; offset += 1 )
    {
        barrier( CLK_GLOBAL_MEM_FENCE );

        if (mapId < vecSize && locId > 0)
        {
            Type y = postSumArray[ mapId + offset ];
            Type y2 = lds[locId-1];
            y = (*binaryOp)( y, y2 );
            postSumArray[ mapId + offset ] = y;
        } // thread in bounds
    } // for 
} // end kernel


/******************************************************************************
 *  Kernel 2
 *****************************************************************************/
//__attribute__((reqd_work_group_size(KERNEL2WORKGROUPSIZE,1,1)))
template< typename Type, typename BinaryFunction >
__kernel void perBlockAddition( 
                global Type* output,
                global Type* postSumArray,
                const uint vecSize,
                global BinaryFunction* binaryOp
                )
{
    size_t gloId = get_global_id( 0 );
    size_t groId = get_group_id( 0 );
    size_t locId = get_local_id( 0 );

    //  Abort threads that are passed the end of the input vector
    if( gloId >= vecSize )
        return;
        
    Type scanResult = output[ gloId ];

    // accumulate prefix
    if (groId > 0)
    {
        Type postBlockSum = postSumArray[ groId-1 ];
        Type newResult = (*binaryOp)( scanResult, postBlockSum );
        output[ gloId ] = newResult;
    }
}

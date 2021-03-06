// Copyright (c) 2016-2017 Intel Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


#if FP16_SUPPORTED
    #pragma OPENCL EXTENSION cl_khr_fp16 : enable

    #if RELU
        #define ACTIVATION(output, input) output = isinf(convert_half(NEGATIVE_SLOPE)) ? ((input >= 0.0h) ? \
        input : -convert_half(NEGATIVE_SLOPE)) : (max(input, 0.0h) + convert_half(NEGATIVE_SLOPE) * min(input, 0.0h));
    #else
        #define ACTIVATION(output, input) output = input;
    #endif

__attribute__((intel_reqd_sub_group_size(16)))
__attribute__((reqd_work_group_size(16, 1, 1)))
KERNEL(convolution_gpu_yxfb_yxio_b16_fp16)(
    const __global half* input,
    __global half* output,
    const __global half* filter,
#if BIAS_TERM
    const __global half* bias,
#endif
    uint split_idx)
{
    // get_global_size(0) -> Number of work items needed to compute all features and all batches for single output spatial position
    //                       (single (x, y) point in output).
    // get_global_size(1) -> Output size in X-dimension.
    // get_global_size(2) -> Output size in Y-dimension.
    // get_global_id(0)   -> Id of work item computing single spatial point of output indicated by get_global_id(1), get_global_id(2).
    // get_global_id(1)   -> Current x-position in output.
    // get_global_id(2)   -> Current y-position in output.
    //
    // WORK_ITEMS_PER_SINGLE_BATCHES_ELEMENTS -> Number of work items needed to compute entire one batch for at least one feature and one spatial point.
    //                                           (this number in current implementation computes also OFM_PER_WORK_ITEM output features at the same time).
    // FILTER_ARRAY_NUM                       -> Number of filters groups (split size).


    const uint linear_id_xy = get_global_id(1) + get_global_size(1) * get_global_id(2);
    uint global_id = (((uint)get_global_id(0) / WORK_ITEMS_PER_SINGLE_BATCHES_ELEMENTS) + (linear_id_xy * FILTER_ARRAY_NUM + split_idx) * (FILTER_OUTPUT_FEATURE_NUM / OFM_PER_WORK_ITEM)) * WORK_ITEMS_PER_SINGLE_BATCHES_ELEMENTS;

    const uint sub_group_id = get_local_id(0);

#if defined(USE_BLOCK_READ_2) || defined(USE_BLOCK_READ_1)
    const uint chunk_size = sizeof(uint)/sizeof(half);
#else
    const uint chunk_size = 1;
#endif

    const uint out_batch_id = chunk_size * sub_group_id + LOCAL_WORK_GROUP_SIZE * BATCHES_PER_WORK_ITEM * ((uint)get_group_id(0) % LOCAL_WORK_GROUPS_PER_SINGLE_BATCHES_ELEMENTS);
    const uint out_x = get_global_id(1);
    const uint out_y = get_global_id(2);

    const uint out_id = (global_id / WORK_ITEMS_PER_SINGLE_BATCHES_ELEMENTS) * OFM_PER_WORK_ITEM * INPUT_BATCH_NUM + out_batch_id;

    const uint ofm_offset = ((global_id * OFM_PER_WORK_ITEM) / WORK_ITEMS_PER_SINGLE_BATCHES_ELEMENTS) % FILTER_OUTPUT_FEATURE_NUM;

    bool finish = false;

    finish = out_x >= OUTPUT_LIMIT_SIZE_X || out_x < OUTPUT_PADDING_LOWER_SIZE_X;
    finish = (out_y >= OUTPUT_LIMIT_SIZE_Y || out_y < OUTPUT_PADDING_LOWER_SIZE_Y) ? true : finish;


    // Each component of vector element contains computation for separate output feature.
    half16 _data[BATCHES_PER_WORK_ITEM];
    for(uint i = 0; i < BATCHES_PER_WORK_ITEM; i++)
    {
        _data[i] = 0.0h;
    }
    if(!finish)
    {
        const int x = out_x * STRIDE_SIZE_X + INPUT_OFFSET_SIZE_X;
        const int y = out_y * STRIDE_SIZE_Y + INPUT_OFFSET_SIZE_Y;

        for (uint i = 0; i < FILTER_SIZE_Y; i++)
        {
            int input_offset_y = y + i;
            bool zero_y = input_offset_y >= INPUT_SIZE_Y || input_offset_y < 0;

            if(!zero_y)
            {
                for (uint j = 0; j < FILTER_SIZE_X; j++)
                {
                    int input_offset_x = x + j;

                    bool zero = input_offset_x >= INPUT_SIZE_X || input_offset_x < 0;

                    if(!zero)
                    {
                        uint input_idx = (input_offset_x + (input_offset_y * INPUT_SIZE_X)) * INPUT_FEATURE_NUM * INPUT_BATCH_NUM;
                        input_idx += split_idx * FILTER_INPUT_FEATURE_NUM * INPUT_BATCH_NUM;
                        input_idx += out_batch_id;

                        //sub_group_id used as offset to make each workitem load different filter, and then shuffle it
                        // 2 * sub_group_id is used because we group 2 halfs as one uint element.
                        uint filter_idx = ofm_offset + 2 * sub_group_id + FILTER_INPUT_FEATURE_NUM * (FILTER_OUTPUT_FEATURE_NUM * (i * FILTER_SIZE_X + j));

                        for (uint h = 0; h < FILTER_INPUT_FEATURE_NUM; h++)
                        {
#if defined(USE_BLOCK_READ_2)
                            half4 _input = as_half4(intel_sub_group_block_read2((const __global uint*)(input + input_idx)));
                            uint filter_val_pair = *(const __global uint*)(filter + filter_idx);
                            half16 filter_transp = TRANSPOSE_BLOCK_16_FP16(filter_val_pair);
                            _data[0] = fma(_input.s0, filter_transp, _data[0]);
                            _data[1] = fma(_input.s1, filter_transp, _data[1]);
                            _data[2] = fma(_input.s2, filter_transp, _data[2]);
                            _data[3] = fma(_input.s3, filter_transp, _data[3]);
                            input_idx += INPUT_BATCH_NUM;
#elif defined(USE_BLOCK_READ_1)
                            half2 _input = as_half2(intel_sub_group_block_read((const __global uint*)(input + input_idx)));
                            uint filter_val_pair = *(const __global uint*)(filter + filter_idx);
                            half16 filter_transp = TRANSPOSE_BLOCK_16_FP16(filter_val_pair);
                            _data[0] = fma(_input.s0, filter_transp, _data[0]);
                            _data[1] = fma(_input.s1, filter_transp, _data[1]);
                            input_idx += INPUT_BATCH_NUM;
#else
                            uint filter_val_pair = *(const __global uint*)(filter + filter_idx);
                            half16 filter_transp = TRANSPOSE_BLOCK_16_FP16(filter_val_pair);
                            for(uint s = 0; s < BATCHES_PER_WORK_ITEM; s++)
                            {
                                _data[s] = fma(input[input_idx], filter_transp, _data[s]);
                                input_idx += LOCAL_WORK_GROUP_SIZE;
                            }
                            input_idx += INPUT_BATCH_NUM - BATCHES_PER_WORK_ITEM * LOCAL_WORK_GROUP_SIZE;
#endif
                            filter_idx += FILTER_OUTPUT_FEATURE_NUM;
                        }
                    }
                }
            }
        }
    }
#if BIAS_TERM
    uint bias_val_pair = *(const __global uint*)(bias + (ofm_offset + 2 * sub_group_id));
    for(uint s = 0; s < BATCHES_PER_WORK_ITEM; s++)
    {
        ADD_BIAS_16_FP16(_data[s], bias_val_pair);
    }
#endif
    for(uint s = 0; s < BATCHES_PER_WORK_ITEM; s++)
    {
        ACTIVATION(_data[s], _data[s]);
    }

#if defined(USE_BLOCK_READ_2) || defined(USE_BLOCK_READ_1)
    for(uint s = 0; s < BATCHES_PER_WORK_ITEM / 2; s++)
    {
        uint _out_id = out_id + chunk_size * s * LOCAL_WORK_GROUP_SIZE;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s0, _data[chunk_size * s + 1].s0)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s1, _data[chunk_size * s + 1].s1)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s2, _data[chunk_size * s + 1].s2)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s3, _data[chunk_size * s + 1].s3)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s4, _data[chunk_size * s + 1].s4)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s5, _data[chunk_size * s + 1].s5)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s6, _data[chunk_size * s + 1].s6)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s7, _data[chunk_size * s + 1].s7)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s8, _data[chunk_size * s + 1].s8)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].s9, _data[chunk_size * s + 1].s9)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].sa, _data[chunk_size * s + 1].sa)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].sb, _data[chunk_size * s + 1].sb)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].sc, _data[chunk_size * s + 1].sc)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].sd, _data[chunk_size * s + 1].sd)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].se, _data[chunk_size * s + 1].se)); _out_id += INPUT_BATCH_NUM;
        *(__global uint*)(output + _out_id) = as_uint((half2)(_data[chunk_size * s].sf, _data[chunk_size * s + 1].sf)); _out_id += INPUT_BATCH_NUM;
    }
#else
    for(uint s = 0; s < BATCHES_PER_WORK_ITEM; s++)
    {
        int _out_id = out_id + s * LOCAL_WORK_GROUP_SIZE;
        output[_out_id] = _data[s].s0; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s1; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s2; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s3; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s4; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s5; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s6; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s7; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s8; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].s9; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].sa; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].sb; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].sc; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].sd; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].se; _out_id += INPUT_BATCH_NUM;
        output[_out_id] = _data[s].sf; _out_id += INPUT_BATCH_NUM;
    }
#endif

    //output[0] = get_sub_group_size();
}

    #undef ACTIVATION
#endif // FP16_SUPPORTED

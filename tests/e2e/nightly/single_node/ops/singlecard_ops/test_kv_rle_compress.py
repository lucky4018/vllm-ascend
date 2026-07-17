# Copyright (c) 2025 Huawei Technologies Co., Ltd. All Rights Reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import gc
import struct

import torch

from vllm_ascend.utils import enable_custom_op

enable_custom_op()

DEFAULT_ATOL = 1e-3
DEFAULT_RTOL = 1e-3


def kv_rle_compress_cpu_impl(x: torch.Tensor) -> tuple[torch.Tensor, int]:
    """
    CPU reference implementation of Zero-Block RLE.
    Matches the AIV kernel behavior exactly.
    """
    total_elements = x.numel()
    BLOCK_WORDS = 64
    HEADER_ALL_ZERO = 0xFF
    MAX_LEADING_ZEROS = 0x3F

    num_blocks = total_elements // BLOCK_WORDS
    has_tail = (total_elements % BLOCK_WORDS) != 0

    output = bytearray()
    # Reserve 4 bytes for total size (will be filled at end)
    output.extend(b'\x00\x00\x00\x00')

    for b in range(num_blocks):
        block = x[b * BLOCK_WORDS:(b + 1) * BLOCK_WORDS]
        # Count leading zeros
        leading_zeros = 0
        for i in range(BLOCK_WORDS):
            if block[i].item() == 0.0:
                leading_zeros += 1
            else:
                break

        if leading_zeros == BLOCK_WORDS:
            output.append(HEADER_ALL_ZERO)
        else:
            header = leading_zeros & MAX_LEADING_ZEROS
            output.append(header)
            # Append non-zero tail as raw bytes
            remaining = block[leading_zeros:]
            output.extend(remaining.cpu().numpy().tobytes())

    if has_tail:
        tail = x[num_blocks * BLOCK_WORDS:]
        tail_words = tail.numel()
        output.append(tail_words)
        output.extend(tail.cpu().numpy().tobytes())

    # Write total size at beginning
    total_size = len(output)
    output[0:4] = total_size.to_bytes(4, 'little')

    return torch.frombuffer(bytes(output), dtype=torch.uint8), total_size


def kv_rle_decompress_cpu_impl(compressed: torch.Tensor, original_num_elements: int) -> torch.Tensor:
    """
    CPU reference implementation of Zero-Block RLE decompression.
    Matches the AIV kernel behavior exactly.
    """
    BLOCK_WORDS = 64
    HEADER_ALL_ZERO = 0xFF
    MAX_LEADING_ZEROS = 0x3F

    data = compressed.cpu().numpy().tobytes()
    cursor = 0

    # Read total size
    total_size = int.from_bytes(data[cursor:cursor + 4], 'little')
    cursor += 4

    num_blocks = original_num_elements // BLOCK_WORDS
    has_tail = (original_num_elements % BLOCK_WORDS) != 0

    output = []

    for b in range(num_blocks):
        header = data[cursor]
        cursor += 1
        if header == HEADER_ALL_ZERO:
            output.extend([0.0] * BLOCK_WORDS)
        else:
            leading_zeros = header & MAX_LEADING_ZEROS
            remaining = BLOCK_WORDS - leading_zeros
            output.extend([0.0] * leading_zeros)
            # Parse FP16 values from remaining bytes
            for i in range(remaining):
                raw_bytes = data[cursor:cursor + 2]
                val = struct.unpack('<e', raw_bytes)[0]
                output.append(val)
                cursor += 2

    if has_tail:
        tail_words = data[cursor]
        cursor += 1
        for i in range(tail_words):
            raw_bytes = data[cursor:cursor + 2]
            val = struct.unpack('<e', raw_bytes)[0]
            output.append(val)
            cursor += 2

    return torch.tensor(output, dtype=torch.float16)


@torch.inference_mode()
def test_kv_rle_compress_random():
    """Test round-trip on random FP16 data."""
    B = 64
    x = torch.randn([B], dtype=torch.float16)
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_50pct_zeros():
    """Test compression on data with 50% leading zeros."""
    B = 64
    x = torch.randn([B], dtype=torch.float16)
    x[:32] = 0.0  # First 32 elements are zero
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    # With 32 zeros, compressed size should be less than original
    # Original: 64 * 2 = 128 bytes
    # Compressed: 4 (size) + 1 (header) + 32*2 (non-zero) = 69 bytes
    expected_size = 4 + 1 + 32 * 2
    assert size.item() <= expected_size + 10, f"Compressed size {size.item()} should be <= {expected_size + 10}"
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_all_zeros():
    """Test compression on all-zero data."""
    B = 64
    x = torch.zeros([B], dtype=torch.float16)
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    # All-zero block should compress to: 4 (size) + 1 (header 0xFF) = 5 bytes
    assert size.item() == 5, f"All-zero block compressed to {size.item()} bytes, expected 5"
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_multi_block():
    """Test compression on multi-block data (256 elements = 4 blocks)."""
    B = 256
    x = torch.randn([B], dtype=torch.float16)
    # Make block 0 all-zero, block 1 50% zeros, block 2-3 random
    x[0:64] = 0.0
    x[64:96] = 0.0  # 50% zeros in block 1
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_non_multiple_block():
    """Test compression on data that doesn't fill a complete block."""
    B = 100  # Not a multiple of 64
    x = torch.randn([B], dtype=torch.float16)
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_large():
    """Test compression on large data (10k elements)."""
    B = 10000
    x = torch.randn([B], dtype=torch.float16)
    x[:5000] = 0.0  # 50% zeros
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_decompress_empty():
    """Test decompressing empty/trivial case."""
    B = 0
    x = torch.zeros([B], dtype=torch.float16)
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()


@torch.inference_mode()
def test_kv_rle_compress_negative_values():
    """Test that negative values are not treated as zeros."""
    B = 64
    x = -torch.randn([B], dtype=torch.float16).abs()  # All negative values
    # Ensure no exact zeros
    x[x.abs() < 1e-6] = -1.0
    x_npu = x.npu().contiguous()

    compressed_npu, size = torch.ops._C_ascend.kv_rle_compress(x_npu)
    output_npu = torch.ops._C_ascend.kv_rle_decompress(compressed_npu, size, B)

    torch.testing.assert_close(output_npu.cpu(), x.cpu(), atol=DEFAULT_ATOL, rtol=DEFAULT_RTOL)
    # With no zeros, worst-case: header=0, all 64 values
    # size = 4 + 1 + 64*2 = 133
    assert size.item() <= 133, f"No-zero block compressed to {size.item()} bytes, expected <=133"
    gc.collect()
    torch.npu.empty_cache()
    torch.npu.reset_peak_memory_stats()
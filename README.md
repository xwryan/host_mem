# host_mem_manager

SystemVerilog/UVM 主机内存模型。两种分配器(Buddy / Linear)、可配置粒度、丰富调试接口。用于验证环境模拟 host memory 的分配、释放、读写。

## 文件结构

```
host_mem.f              工程 filelist：-f $HOST_MEM_ROOT/host_mem.f
src/
  host_mem_pkg.sv       唯一编译入口: 常量、typedef、API、manager、pool
  host_mem_macros.svh   调用端便捷宏（独立编译时显式 include）
  host_mem_manager.sv   包内 class: 主机内存管理器
  host_mem_pool.sv      包内 class: 按 host_id 共享 manager 的所有权池
tb/
  host_mem_tb.sv        testbench: 23 个测试用例
docs/                   设计文档
```

## 编译运行

```bash
export HOST_MEM_ROOT=$PWD
vcs -sverilog -full64 +v2k -ntb_opts uvm-1.2 -f $HOST_MEM_ROOT/host_mem.f \
    tb/host_mem_tb.sv -o simv -l compile.log
./simv
```

支持 VCS Q-2020.03+。

工程编译只加 `-f $HOST_MEM_ROOT/host_mem.f`（`+incdir+src` 与 `src/host_mem_pkg.sv`），不要单独编译或
再次 include `host_mem_manager.sv` / `host_mem_pool.sv`。调用方在自己的 package、
module 或 program 中使用 `import host_mem_pkg::*;`，也可使用
`host_mem_pkg::host_mem_manager` / `host_mem_pkg::host_mem_pool`。
使用便捷宏时显式 include `host_mem_macros.svh`，因为 `import` 不会导入宏。
测试保持在包外；`host_mem_bigregion_tb.sv` 可替换上述基本测试入口，
`host_mem_random_tb.sv` 是 Virtio 集成测试，还需先编译其 DPU、PCIe 和 Virtio 依赖。

## 核心概念

### 两种分配模式

| 模式 | 算法 | 适用场景 | 浪费 |
|---|---|---|---|
| `MODE_BUDDY` | Buddy System (pow2 取整 + 合并) | 大量混合大小,大 region | pow2 取整,最坏 ~50% |
| `MODE_LINEAR` | 线性 first-fit + 相邻 merge | 小 CPU 内存,真实占用 | 仅 granule 取整 |

### 随机布局与 Host 隔离

`host_mem_manager` 的 `HOST_MEM_RANDOM`（默认）在已初始化且有 backing
storage 的 aperture 内随机选择对齐地址；`HOST_MEM_FIRST_FIT` 保留用于稳定调试。
随机源直接使用仿真器/UVM 的随机状态，不另设 seed 字段，因此相同仿真 seed、配置和
调用顺序可复现。`host_mem_pool` 为每个 `host_id` 持有唯一 manager：同 Host 的
VIO/RDMA/VBLK 共享对象，不同 Host 即使数值 GPA 相同也相互隔离。

BAR/MMIO 等非 RAM 区间可在第一次业务分配前调用：

```systemverilog
host_mem_pool pool;
pool = host_mem_pool::type_id::create("pool");
void'(pool.create_host(0, 64'h1_0000_0000, 64'h1_FFFF_FFFF,
                       MODE_BUDDY, 16, HOST_MEM_RANDOM));
assert(pool.get_host(0).reserve_range(64'h1_0000_4000, 64'h1000, "BAR0"));
```

冻结 DPU snapshot 中完全落入该 aperture 的 BAR 由 Virtio 环境自动导入；位于独立
MMIO aperture 的 BAR 不占用 Host backing storage，部分相交会拒绝配置。相同 BAR 的
重复导入是幂等的。

### 可配置 granule

最小可寻址块。`pow2 ∈ [1, 64]`。默认 16。

- 越小 → 浪费越少,但 reverse_map 膨胀
- 越大 → 内存更省 host RAM,但小 alloc 浪费大

| granule | 1×16B 块占用 | 1MB region reverse_map 上限 |
|---|---|---|
| 4 | 16B | ~256K entries |
| 16 (默认) | 16B | ~64K entries |
| 64 | 64B | ~16K entries |

## 快速上手

### 基本流程

```systemverilog
`include "host_mem_macros.svh"
import host_mem_pkg::*;

host_mem_manager mem;
bit [63:0] addr;
byte data[];

initial begin
    mem = new("mem");
    mem.init_region(64'h0, 64'hFFFF);  // 默认: MODE_BUDDY, granule=16

    `host_mem_alloc(mem, addr, 100, 64);    // 分配 100B,对齐 64
    data = new[100];
    foreach (data[i]) data[i] = i;
    `host_mem_write(mem, addr, data);
    `host_mem_read(mem, addr, 100, data);
    `host_mem_free(mem, addr);

    `host_mem_leak_check(mem);
end
```

### init_region 完整签名

```systemverilog
function void init_region(bit [63:0] base_addr,
                          bit [63:0] end_addr,
                          alloc_mode_e m = MODE_BUDDY,
                          int unsigned granule = DEFAULT_MIN_GRANULE,  // 16
                          byte poison = DEFAULT_POISON);               // 8'hDE
```

可多次调用注册多个 region(同实例)。

### 典型配置示例

```systemverilog
// 大压测: buddy + granule 64,host 内存最省
stress_mem.init_region(0, 32'hFFFFFF, MODE_BUDDY, 64);

// 16B 描述符: linear + granule 16 (默认)
desc_mem.init_region(0, 32'hFFFFF, MODE_LINEAR);

// 1B/4B tiny alloc: linear + granule 4
tiny_mem.init_region(0, 32'h7FFF, MODE_LINEAR, 4);

// 自定义 poison
mem.init_region(0, 32'hFFFF, MODE_BUDDY, 16, 8'hCC);
```

## API 参考

### 便捷宏 (推荐)

宏会自动注入 `__FILE__`/`__LINE__`,定位错误超清晰。

```systemverilog
`host_mem_alloc(mem, addr, size, align=1)
`host_mem_free(mem, addr)
`host_mem_write(mem, addr, byte_array)
`host_mem_read(mem, addr, size, byte_array)
`host_mem_set(mem, addr, value, size)
`host_mem_cpy(mem, dst, src, size)
`host_mem_compare(mem, result, addr1, addr2, size, mismatch_offset)
`host_mem_release_range(mem, addr, size)
`host_mem_leak_check(mem)
```

### 直接函数调用

```systemverilog
function bit [63:0] alloc(int unsigned size,
                          int unsigned align = 1,
                          string file = "", int line = 0);
function void free(bit [63:0] addr, string file = "", int line = 0);
function void write_mem(bit [63:0] addr, byte data[],
                        string file = "", int line = 0);
function void read_mem(bit [63:0] addr, int unsigned size, ref byte data[],
                       input string file = "", input int line = 0);
function void mem_set(bit [63:0] addr, byte value, int unsigned size, ...);
function void mem_cpy(bit [63:0] dst, bit [63:0] src, int unsigned size, ...);
function bit  mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size,
                          output int unsigned mismatch_offset, ...);
function void release_range(bit [63:0] addr, int unsigned size, ...);
function int unsigned get_min_granule();
```

### 调试

```systemverilog
mem.hexdump(addr, size);        // 类 Linux hexdump,折叠重复行
mem.print_alloc_table();        // 列出所有未释放块
mem.print_stats();              // 总量/已分配/碎片/op 计数
mem.print_history(last_n=0);    // 最近 N 条 ALLOC/FREE 历史
mem.leak_check();               // 泄漏检查
```

### 运行时配置字段 (public)

```systemverilog
mem.poison_pattern      = 8'hDE;  // free 后填充值
mem.warn_on_poison_read = 1;      // 读全 poison 区时 warning(疑似 UAF)
```

## 安全检测

自动 FATAL 触发:

| 场景 | 检测 |
|---|---|
| 重复 free | `Double-free detected`(附上次 free 位置) |
| 越界访问 | `Access exceeds block boundary` |
| 访问已 release_range 区 | `Accessing released sub-range` |
| 未分配地址读写 | `Accessing unallocated address` |

所有 FATAL 自带 `__FILE__:__LINE__`,定位准确。

## release_range 部分释放

按 granule 粒度部分释放:

```systemverilog
`host_mem_alloc(mem, addr, 16384, 4096);  // 16KB DMA buffer
// DMA 完成 64B 一段,逐段释放
for (int i = 0; i < 256; i++) begin
    `host_mem_release_range(mem, addr + i * 64, 64);
end
// 最后一段释放时自动 free 整块
```

注意: `release_range` 释放完整个 buddy_size/occupation 后会**自动 free**。混用 `release_range` + `free` 时要小心 double-free。

## Linear 模式细节

- `init_region(..., MODE_LINEAR, ...)` 开启
- alloc 真实 size,不 pow2 取整
- align 强制 ≥ granule (保 reverse_map 一致)
- free 任意顺序,左右相邻 free 段自动合并
- `print_stats` 显示 free segment 数

```systemverilog
// 32KB CPU 内存,装 100/200/1000/17000 字节
mem.init_region(0, 32'h7FFF, MODE_LINEAR, 16);
`host_mem_alloc(mem, a0, 100);    // 占用 112B
`host_mem_alloc(mem, a1, 200);    // 占用 208B
`host_mem_alloc(mem, a2, 1000);   // 占用 1008B
`host_mem_alloc(mem, a3, 17000);  // 占用 17008B
// 总 18336B / 32768B, 还剩 14432B
// Buddy 模式下 17000 单独就吃 32KB → OOM
```

## 测试用例 (tb/host_mem_tb.sv)

23 个测试,VCS 实测 ~15s:

| # | 名称 | 模式 |
|---|---|---|
| 1-10 | 基础 alloc/free/读写/越界/double-free 检测 | buddy |
| 11 | 1MB region 256 块随机分配 + 数据校验 | buddy |
| 12 | 5 轮碎片化 + 合并恢复 | buddy |
| 13 | DMA 16KB 分 256 段 release_range | buddy |
| 14 | 多 region 大块分配 | buddy |
| 15 | 1000 次 alloc/free thrash | buddy |
| 16 | 500 次随机 size/align 混合 | buddy |
| 17 | 15K 次随机压测 + dup-addr + 数据腐烂检测 | buddy |
| 18 | 32KB 小 CPU 内存,4 块奇数 size | linear |
| 19 | 8 块乱序 free + merge 全恢复 | linear |
| 20 | 15K 次随机压测 + dup + 数据校验 | linear |
| 21 | 3K 次 alloc/free/release_range 混合 | buddy |
| 22 | 200 块碎片化 + survivor 校验 + merge | linear |
| 23 | 三 granule (4/16/64) 16B workload 对比 | linear |

### 性能数据 (VCS Q-2020.03 实测)

| 配置 | 仿真时间 |
|---|---|
| 全 23 测试,默认 granule=16 | 15.4s |
| 仅 buddy 模式下 Test 17 (15K op) | ~5s |
| 仅 linear 模式下 Test 20 (15K op) | ~6s |

granule=4 比 granule=16 慢约 30-50% (reverse_map 操作多)。granule=64 比 granule=16 快约 15%。

## 不支持/限制

- 仅 simulation,无 RTL hooks
- granule 上限 64,下限 1
- region 总数无硬限,但越多 stats 输出越长
- 不支持线程安全(单 testbench thread)
- `release_range` 要求 addr/size 都按 granule 对齐

## 设计文档

详细架构: `docs/superpowers/specs/2026-04-13-host-mem-manager-design.md`
开发计划: `docs/superpowers/plans/2026-04-13-host-mem-manager.md`

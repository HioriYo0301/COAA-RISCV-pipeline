# Lab1 架构与逻辑详尽解析文档

## 1. 全局数据通路与控制流

### 1.1 指令生命周期追踪：以 `add` 和 `addi` 为例

#### `add x1, x2, x3` 指令在五级流水线中的流转：

```
时钟周期  IF          IF/ID       ID          ID/EX       EX          EX/MEM      MEM         MEM/WB      WB
─────────────────────────────────────────────────────────────────────────────────────────────────────────
T0    取指(add)→    ←add        译码(add)→   ←add        执行(add)→   ←add        直通→       ←add        写回✓
T1    取指(next)→   ←next       译码(next)→  ←next       执行(next)→  ←next       直通→       ←next       写回✓
```

**各阶段详解**：

1. **IF 阶段 (T0)**：
   - `fetch` 模块发出 `ireq.valid=1, ireq.addr=PC`
   - 等待 `iresp.data_ok=1` 后捕获指令 `0x003100b3` (add x1,x2,x3)
   - `pc <= PC + 4`，`if_id <= {valid=1, pc=0x80000000, instr=0x003100b3}`

2. **ID 阶段 (T1)**：
   - `decode` 模块从 `if_id.instr` 提取字段：
     - `opcode=0110011`, `rd=1`, `rs1=2`, `rs2=3`, `funct3=000`
   - 控制信号生成：`wen=1, use_imm=0, is_sub=0`
   - 寄存器读取：`rs1_addr=2 → rdata1=gpr[2]`, `rs2_addr=3 → rdata2=gpr[3]`
   - WB 旁路检查：无冲突，使用寄存器堆读取值
   - 输出：`id_ex_next = {valid=1, src1=gpr[2], src2=gpr[3], ...}`

3. **EX 阶段 (T2)**：
   - `execute` 模块转发检测：
     - 检查 `ex_mem.rd(未知) == rs1(2)` → 不匹配
     - 检查 `mem_wb.rd(未知) == rs1(2)` → 不匹配
     - 使用 `id_ex.src1` 值
   - ALU 运算：`funct3=000, is_sub=0` → `result = src1 + src2`
   - 输出：`ex_mem_next = {valid=1, result=gpr[2]+gpr[3], ...}`

4. **MEM 阶段 (T3)**：
   - 本设计中为直通阶段，`mem_wb <= ex_mem` 无额外操作

5. **WB 阶段 (T4)**：
   - `regfile.wen=1, waddr=1, wdata=result`
   - 在 posedge 更新 `gpr[1] <= result`
   - Difftest 提交：`InstrCommit.valid=1, wdest=1, wdata=result`

#### `addi x4, x5, 100` 指令流转：

```
T0: IF(addi) → T1: ID(addi, imm={{52{0}},64'd100}) → T2: EX(result=gpr[5]+100) → T3: MEM(直通) → T4: WB(gpr[4]<=result)
```

关键差异：
- ID 阶段：`use_imm=1`，`imm` 为符号扩展的立即数 100
- EX 阶段：`alu_b = imm` 而非 `fwd_src2`

### 1.2 ibus 握手协议与流水线停顿机制

#### 总线信号时序图：

```
时钟 ↑    ireq.valid  ireq.addr   iresp.data_ok  iresp.data    动作
─────────────────────────────────────────────────────────────────────
T0   ↑    1           0x80000000  0              --            发起请求
T1   ↑    1           0x80000000  0              --            等待响应
T2   ↑    1           0x80000000  1              0x003100b3    响应就绪
T3   ↑    1           0x80000004  0              --            PC递增，请求下条
```

#### 停顿控制逻辑：

```verilog
// fetch.sv 中的核心控制
always_ff @(posedge clk) begin
    if (iresp.data_ok) begin
        if_id.valid <= 1'b1;    // 捕获指令
        pc          <= pc + 4;  // 推进PC
    end else begin
        if_id.valid <= 1'b0;    // 插入气泡
    end
end
```

**硬件原理**：
- `data_ok=0` 时 IF/ID.valid=0，后续 ID/EX.valid 也为 0
- 流水线自然插入 NOP（气泡），无需额外控制信号
- 这是"阻塞式取指"策略，简单可靠但可能降低 IPC

## 2. 核心难点剖析：转发单元 (Forwarding Unit)

### 2.1 多路选择器硬件实现

#### EX 阶段转发逻辑（execute.sv）：

```verilog
// src1 转发 MUX 的门级映射
always_comb begin
    // 硬件综合为优先级编码器：
    // sel[1] = ex_mem.valid & ex_mem.wen & (ex_mem.rd == rs1) & (ex_mem.rd != 0)
    // sel[0] = mem_wb.valid & mem_wb.wen & (mem_wb.rd == rs1) & (mem_wb.rd != 0)
    // out = sel[1] ? ex_mem.result : (sel[0] ? mem_wb.result : id_ex.src1)
    
    if (ex_mem.valid && ex_mem.wen && ex_mem.rd != 0 && ex_mem.rd == id_ex.rs1)
        fwd_src1 = ex_mem.result;     // 选择输入0
    else if (mem_wb.valid && mem_wb.wen && mem_wb.rd != 0 && mem_wb.rd == id_ex.rs1)
        fwd_src1 = mem_wb.result;     // 选择输入1
    else
        fwd_src1 = id_ex.src1;        // 选择输入2
end
```

**硬件结构**：
- 综合为多路选择器（MUX）+ 优先级检测逻辑
- 每个条件检测约为 4-5 个 gate 延迟
- EX/MEM 路径延迟最小（距离最近），优先级最高

### 2.2 转发优先级设计原理

#### 为什么 EX/MEM 优先级高于 MEM/WB？

**物理原因**：信号传播延迟与流水线距离的关系

```
指令序列：I1: add x1, x2, x3    I2: add x4, x1, x5    I3: add x6, x4, x7

时钟 T2: I1 在 EX 阶段 (result=x2+x3)    ← 最新结果
时钟 T3: I1 在 MEM 阶段                  I2 在 EX 阶段 (需读 x1)
时钟 T4: I1 在 WB 阶段 (写 gpr[1])       I2 在 MEM 阶段    I3 在 EX 阶段 (需读 x4)

I3 在 EX 阶段需要 x4：
- EX/MEM 路径：I2.result (T2 计算) → T4 直接使用（延迟 2 周期）
- MEM/WB 路径：I1.result (T2 计算) → 写 gpr[1] (T4) → 读 gpr[1] (T4 同周期) → 延迟 2 周期但有竞争风险
```

**关键洞察**：
- EX/MEM 转发提供**最新数据**且**无读写竞争**
- MEM/WB 转发虽数据相同，但涉及寄存器堆读取，增加延迟和功耗
- 硬件设计准则：优先选择延迟最小、确定性最高的路径

### 2.3 转发失效场景分析

#### 不会触发转发的情况：

1. **WRW 冒险（写后写）**：
   ```assembly
   add x1, x2, x3    # I1
   add x1, x4, x5    # I2：I2 覆盖 I1 结果
   add x6, x1, x7    # I3：必须等待 I2 WB 完成，不能转发 I1
   ```

2. **控制冒险**：
   - 本设计无分支预测，转发逻辑对所有指令生效
   - 若未来加入跳转指令，需Flush流水线，转发临时失效

## 3. 软件思维到硬件思维的映射

### 3.1 C/C++ 串行执行 vs 硬件并行执行

#### 软件视角（伪代码）：
```cpp
for (int i = 0; i < instr_count; i++) {
    fetch();      // 10ns
    decode();     // 5ns
    execute();    // 8ns
    memory();     // 3ns
    writeback();  // 2ns
    // 总时间：28ns/指令
}
```

#### 硬件视角（同一周期）：
```verilog
// 所有模块在同一个 posedge 并发工作
always @(posedge clk) begin
    fetch_stage();      // comb_logic + FF (关键路径决定时钟频率)
    decode_stage();     // comb_logic + FF
    execute_stage();    // comb_logic + FF
    memory_stage();     // comb_logic + FF
    writeback_stage();  // comb_logic + FF
    // 实际延迟：关键路径延迟（如 2ns）决定最大频率（500MHz）
end
```

**本质差异**：
- **软件**：时间分片，串行复用执行单元
- **硬件**：空间并行，每个阶段有专用电路同时工作
- **性能收益**：理想情况下 IPC = 5（每周期完成5条指令的不同阶段）

### 3.2 硬件资源共享与软件变量独占

#### 寄存器堆的双端口设计：

```verilog
// regfile.sv 中的双读端口
assign rdata1 = (raddr1 == 0) ? 64'd0 : gpr[raddr1];  // 端口A
assign rdata2 = (raddr2 == 0) ? 64'd0 : gpr[raddr2];  // 端口B

// 硬件实现：两个独立的读出放大器 + 地址译码器
// 成本：面积增加约 2x，但支持同时读取两个操作数
```

**对比软件**：
```cpp
int gpr[32];
int src1 = gpr[rs1];  // 第一次访存
int src2 = gpr[rs2];  // 第二次访存（串行）
```

**硬件优势**：
- 零延迟并发读取（组合逻辑）
- 但写入仍需时序逻辑串行化（单端口写入）

## 4. 助教刁难问题题库 (Mock Interview Q&A)

### Q1: 如果一直收不到 `iresp.data_ok`，流水线会怎样？

**A**: 流水线会持续插入气泡，不会死锁。

**详细分析**：
```verilog
// fetch.sv 核心逻辑
if (iresp.data_ok) begin
    if_id.valid <= 1'b1;  // 捕获指令
    pc <= pc + 4;
end else begin
    if_id.valid <= 1'b0;  // 插入气泡，PC 不变
end
```

- `if_id.valid=0` → `id_ex.valid=0` → 整个流水线清空
- `pc` 保持不变，不断重试同一地址
- `halt_seen` 机制防止总线冲突（无新请求发出）
- **不是死锁**：一旦 `data_ok=1` 恢复，流水线自动填充

**陷阱点**：考生可能误认为需要超时检测或复位机制。

---

### Q2: 为什么转发检测条件要检查 `rd != 0`？

**A**: 避免与 x0 硬连线冲突。

**硬件原理**：
- x0 在寄存器堆中物理接地（硬连线为 0）
- 对 x0 的写入被忽略：`if (waddr != 0) gpr[waddr] <= wdata;`
- 若转发逻辑不检查 `rd != 0`：
  ```verilog
  // 错误示例
  if (ex_mem.valid && ex_mem.wen && ex_mem.rd == rs1)  // rd=0 时也转发
      fwd_src1 = ex_mem.result;  // 但 ex_mem.result 可能非 0
  ```
  会导致读取 x0 时获得错误的非零值，违反 RISC-V 架构语义。

**设计哲学**：硬件约束必须与 ISA 语义保持一致。

---

### Q3: `gpr_next` 旁路机制的时序正确性如何证明？

**A**: 通过组合逻辑在 posedge 前计算"视作已写入"的状态。

**形式化验证**：
```
时钟周期 T：
- posedge 前：gpr_next[i] = wen && (waddr==i) ? wdata : gpr[i]  // 组合逻辑
- posedge 时：gpr[i] <= wen && (waddr==i) ? wdata : gpr[i]      // 时序逻辑
- posedge 后：Difftest 读取 gpr_next[i]                         // 看到新值
```

**关键不变量**：
```
∀i≠0: gpr_next[i] = (时序上一周期写入的值) ∨ (当前组合旁路的值)
```

这确保 Difftest 在指令提交时看到**逻辑上已生效**的寄存器状态。

---

### Q4: 流水线深度为5，理论 IPC 上限是多少？实际能达到吗？

**A**: 理论上限 IPC=1（本设计），实际可达到。

**理论分析**：
- 无冒险的理想情况：IPC = 1（每周期完成1条指令）
- 因为：
  - IF 阶段每2周期才能获得1条指令（CBusArbiter + RAM延迟）
  - 即使流水线填满，吞吐率仍受限于取指带宽
  - 实际 IPC ≈ 0.5（测试结果验证）

**提升方案**：
- 增加指令缓存（I-Cache）减少取指延迟
- 实现多发射（超标量）同时处理多条指令
- 加入分支预测消除控制冒险

**教学意义**：让学生理解流水线深度 ≠ 性能线性提升。

---

### Q5: 如果在 EX 阶段检测到非法指令，如何处理？

**A**: 本设计无法处理，会静默错误。需加入异常处理机制。

**现状问题**：
```verilog
// execute.sv
always_comb begin
    case (id_ex.funct3)
        3'b000: alu_result = ...;
        ...
        default: alu_result = 64'd0;  // 未定义操作码返回 0
    endcase
end
```

**改进方案**：
1. 添加 `illegal_inst` 检测标志
2. 在 ID 阶段译码时识别非法指令
3. 设置异常标志，触发 trap 处理
4. 需要 Flush 流水线并跳转到异常处理程序

**深层思考**：这引出 CPU 安全性设计的重要性——非法输入必须有明确定义的行为。

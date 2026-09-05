# oci-arm-catcher-turbo 🚀

极简、可靠、无人值守的 **Oracle Cloud (甲骨文云) ARM (`VM.Standard.A1.Flex`) 自动抢机脚本**。
<img width="1080" height="2344" alt="image" src="https://github.com/user-attachments/assets/67d32953-d843-4371-9dbf-efbd12571659" />


基于官方 **OCI CLI** 实现，支持多 AD 自动轮询、`--no-retry` 精确节流、成功即停零重复开机保障，并内置 **Server酱微信通知**。

---

## ✨ 核心特性

- 🎯 **轻量零多余依赖**：纯原生 Bash + 官方 OCI CLI + `jq` + Python 3 标准库（用于安全发 HTTP 请求）。
- ⏱️ **精确重试控制 (`--no-retry`)**：避免 OCI CLI 底层 SDK 内部隐蔽的指数退避重试拖慢节奏，严格按自定义时间（如 60~120s 随机浮动）发起轮询。
- 🔄 **多 AD 自动轮换**：自动拉取所在区域全部可用区（Availability Domains）并轮流尝试。
- 🛡️ **防刷爆与防反向扣费**：
  - **抢到即止**：实例创建成功后立即退出（Exit 0），搭配 `Restart=on-failure` 的 systemd 守护服务，**永久停止运行，绝不开第二台**。
  - **致命错误熔断**：遇到鉴权失败、OCID 无效、配额彻底为 0 等不可恢复错误时立即终止，避免无意义死循环封号。
- 📲 **微信实时推送**：开机成功后自动查询分配到的公网 IP，并直接通过 Server酱推送卡片消息到你的微信。

---

## 📋 准备工作

### 1. 基础环境
- 一台已有的 Linux 机器（例如甲骨文原有的免费 AMD 实例 `VM.Standard.E2.1.Micro` 或任意 VPS/本地 Linux）。
- 系统已安装 `jq` 与 `python3`：
  ```bash
  sudo apt-get update && sudo apt-get install -y jq python3
  ```

### 2. 安装并配置 OCI CLI
```bash
# 官方一键安装脚本
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# 确保环境变量生效
export PATH="$HOME/bin:$PATH"

# 验证安装
oci --version
```
运行 `oci setup config`，根据引导填入 `User OCID`、`Tenancy OCID`、`Region` 并上传公钥至 Oracle 控制台完成配置。

---

## 🚀 快速上手

### 1. 克隆本项目
```bash
git clone https://github.com/raclen/oci-arm-catcher-turbo.git
cd oci-arm-catcher-turbo
```

### 2. 生成新机器专用的 SSH 密钥对
```bash
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/oracle_arm -C "oracle-arm-key"
```

### 3. 配置 `.env`
复制配置模板并填写你的参数：
```bash
cp .env.example .env
nano .env
```

| 参数名 | 说明 | 获取方式 |
| :--- | :--- | :--- |
| `COMPARTMENT_ID` | 租户或区间 OCID | 控制台 `租户详细信息` 复制 OCID |
| `SUBNET_ID` | 虚拟子网 OCID | 控制台 `网络 -> 虚拟云网络 (VCN) -> 子网` 复制 OCID |
| `IMAGE_ID` | 系统映像 OCID | 控制台 `计算 -> 定制映像 / 官方映像` 对应 ARM 版 OCID |
| `SSH_KEY_FILE` | 公钥绝对路径 | 即刚才生成的公钥：`/home/ubuntu/.ssh/oracle_arm.pub` |
| `OCPUS` | CPU 核心数 | 推荐 `1`（Always Free 上限为 4） |
| `MEMORY_GB` | 内存容量 (GB) | 推荐 `6`（Always Free 上限为 24） |
| `SERVERCHAN_SENDKEY`| 微信推送密钥 | [Server酱官网](https://sct.ftqq.com/) 微信扫码获取 |

### 4. 手动测试运行
```bash
chmod +x catcher.sh
./catcher.sh
```
若日志提示 `Out of host capacity or AD busy. Retrying...`，说明配置完全正确，正在等待机房释放容量。

---

## 🕒 配置 Systemd 后台长期无人值守

如果你希望关掉终端后，脚本在后台 24 小时自动抢机，可以使用 systemd：

1. 编辑并复制服务文件：
   ```bash
   sudo cp oci-arm-catcher.service /etc/systemd/system/
   ```
   *(注意检查 service 文件中的 User 与 WorkingDirectory 是否与你的实际路径匹配)*

2. 重新加载并启动：
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable oci-arm-catcher
   sudo systemctl start oci-arm-catcher
   ```

3. 查看运行状态与日志：
   ```bash
   # 查看服务运行状态
   sudo systemctl status oci-arm-catcher

   # 实时跟踪抢机日志
   tail -f catcher.log
   ```

---

## 📱 抢到机器后的通知效果

一旦机房容量释放并成功创建实例，你的微信将收到如下通知：

```markdown
🎉 甲骨文 ARM 抢机成功！
- 实例名称: arm-1c6g
- 规格: 1 OCPU / 6 GB 内存 (VM.Standard.A1.Flex)
- 公网 IP: 146.56.xxx.xxx
- 可用区: jaJK:AP-CHUNCHEON-1-AD-1
- 实例 OCID: ocid1.instance.oc1...
```
同时后台 systemd 自动停止，绝不继续占用任何资源或扣除额外费用！

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。

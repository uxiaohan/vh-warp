# vh-warp

🥝 轻量级 Docker 镜像封装 Cloudflare WARP，快速搭建局域网可访问的代理服务，极简部署、极致性能、极其稳定。

## 特性
- 🚀 一键部署：Docker 化封装，无需复杂配置，快速启动 WARP 代理
- 🌐 局域网共享：代理服务暴露至局域网，多设备共用 WARP 网络
- 📝 日志整洁：WARP 日志隔离存储，Docker 日志无冗余输出
- 📦 日志可控：自动轮转+大小限制，避免日志文件占用过多空间
- 🔧 自动自愈：WARP 连接断开/进程异常时自动重启恢复
- 💻 多架构适配：支持 amd64/arm64（服务器/软路由均适用）
- 🔑 账号管理：支持 WARP 账号配置，warp各种账号类型，包括 Team


## 快速开始

### 构建镜像

```sh
git clone https://github.com/uxiaohan/vh-warp.git
cd vh-warp
docker buildx build --no-cache -t vh-warp:latest .
```

### 启动容器

```sh
docker run -d \
  --name vh-warp \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --cap-add=MKNOD \
  --device-cgroup-rule 'c 10:200 rwm' \
  -p 16666:16666 \
  --sysctl net.core.somaxconn=65535 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  uxiaohan/vh-warp:latest
```

### 更换自己的 WARP 账号

```sh
# 断开连接
warp-cli --accept-tos disconnect
# 删除原有账号
warp-cli --accept-tos registration delete
# 新建账号
# warp-cli --accept-tos registration new
# 可直接Token登录
# 获取Token：https://uxiaohan.cloudflareaccess.com/warp
warp-cli --accept-tos registration token '你的Tokken'
# 查看登录信息
warp-cli --accept-tos registration show

# 最后重启容器即可
```

![切换账号截图](account.png)


### 使用代理

局域网内设备配置代理地址（支持 HTTP/SOCKS5 混合代理）

![使用代理截图](proxy.png)



### 构建截图

![树莓派4B构建截图](build.png)

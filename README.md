# Oracle Database 11.2.0.4 on Docker (oraclelinux:7)

在 Docker 里构建并运行 Oracle Database 11.2.0.4 EE。镜像构建阶段只安装 Oracle 软件，数据库本身在容器**首次启动**时通过 `dbca` 静默建库，数据文件、spfile、密码文件、闪回恢复区都落在挂载的持久化数据卷里，容器可以随意删除重建而不丢数据。

## 目录结构

```
.
├── Dockerfile              # 镜像构建定义
├── build.sh                # 构建镜像
├── start.sh                # 创建并启动容器
├── stop.sh                 # 停止容器
├── .env / .env.example     # 运行参数配置
├── database/
│   ├── p13390677_112040_Linux-x86-64_1of7.zip   # Oracle 官方安装介质（需自行放置，见下）
│   └── p13390677_112040_Linux-x86-64_2of7.zip
├── response/
│   └── db_install.rsp      # runInstaller 静默安装的响应文件
└── scripts/
    ├── env.sh              # 容器内统一的 Oracle 环境变量
    ├── entrypoint.sh       # 容器 ENTRYPOINT，root 降权入口
    ├── run-oracle.sh       # PID 1 主脚本：建库/启库/监听/保活
    └── healthcheck.sh      # Docker HEALTHCHECK 探测脚本
```

## 准备工作

### 1. 安装介质

把官方发布的两个安装 zip 直接放到 `database/` 目录下，不需要自己解压/合并/打包：

```
database/p13390677_112040_Linux-x86-64_1of7.zip
database/p13390677_112040_Linux-x86-64_2of7.zip
```

如果这两个文件是从网络下载或者经过多次拷贝得到的，建议先自行用 `unzip -tq <文件>` 校验一遍完整性（`build.sh` 里也有这一步，但提前确认能省掉一次几十分钟的失败构建）。

构建镜像时会在 builder 阶段把这两个 zip 依次解压到同一个安装目录（两者内部路径不重叠，解压顺序无关）。`build.sh` 会校验两个文件是否存在、非空、zip 完整、且第一个包内含 `database/runInstaller`，缺一不可。

> **文件权限要求**：两个 zip 必须至少对其他用户可读（`chmod 644`）。构建时这两个文件是以 bind mount 的方式挂给 builder 阶段的 `oracle` 用户读取的，如果从别处下载/拷贝后权限是 `600`（仅所有者可读），会在 `unzip` 时报 `Permission denied` 导致构建失败。下载完建议顺手 `chmod 644 database/*.zip`。

### 2. 配置 .env

```bash
cp .env.example .env
```

关键变量：

| 变量 | 说明 | 默认值 |
|---|---|---|
| `ORACLE_PWD` | SYS/SYSTEM 密码，**必须在首次启动前修改** | `Oracle_123`（仅示例，务必改掉） |
| `ORACLE_SID` | 实例名 | `ORCL` |
| `ORACLE_MEMORY_MB` | dbca 建库时的 SGA+PGA 总内存 | `2048` |
| `IMAGE_NAME` | 镜像 tag | `oracle/database:11.2.0.4-ee` |
| `CONTAINER_NAME` | 容器名 | `oracle11204` |
| `CONTAINER_MEMORY` | 容器可用内存上限（Docker `--memory`） | `6g` |
| `SHM_SIZE` | `/dev/shm` 大小，Oracle SGA 依赖它 | `3g` |
| `DATA_MODE` | `bind`（默认，数据目录可直接在宿主机浏览）或 `volume`（Docker 管理，macOS 上 I/O 更快但不能直接浏览） | `bind` |
| `DATA_DIR` | `bind` 模式下的宿主机数据目录 | 项目目录下的 `oracle_data`（即 `<project>/oracle_data`） |
| `VOLUME_NAME` | `volume` 模式下的 named volume 名 | `oracle11204-data` |

`.env` 不要提交到版本库（已在 `.dockerignore` 里排除）。

## 构建镜像

```bash
chmod +x build.sh start.sh stop.sh scripts/*.sh
./build.sh
```

- 默认平台 `linux/amd64`（Apple Silicon 上通过 Rosetta/QEMU 跑，构建和首次建库会比较慢，正常现象）。
- 容器时区固定为 `Asia/Shanghai`（`/etc/localtime` 在运行时镜像构建阶段写入），容器内 `date`、alert log 时间戳、`SYSDATE` 都跟宿主机一致，不再是 UTC。需要改成别的时区可以在 `docker build` 时传 `--build-arg TZ_NAME=Xxx/Xxx`。
- 需要不使用缓存全量重建：`./build.sh --no-cache`。
- 构建日志较长，建议保留输出到文件排查问题：`./build.sh 2>&1 | tee build.log`。
- `Dockerfile` 采用两阶段构建：builder 阶段安装 Oracle 软件，最终阶段只 `COPY --from=builder` 拷贝安装完成后的文件树，构建过程中的中间产物（安装介质、解压临时文件、`runInstaller` 中间层）不会进入最终镜像。实测镜像体积约 **4.85GB**（单阶段构建时是 12GB）。

## 导出 / 导入离线镜像

镜像构建好之后约 4.85GB，如果目标环境无法访问 Docker Hub 或者内部镜像仓库，可以导出成一个文件，拷到目标机器上离线导入，不需要重新走一遍 `runInstaller` 静默安装。

导出（在能访问镜像的机器上）：

```bash
docker save oracle/database:11.2.0.4-ee | gzip > oracle11204-image.tar.gz
```

导出的文件用 gzip 压缩后通常还有几 GB，建议用 `rsync`/U 盘/内部文件服务器传输，而不是走公共网络。

导入（在目标机器上）：

```bash
gunzip -c oracle11204-image.tar.gz | docker load
```

导入后镜像名和 tag 会保持一致（`oracle/database:11.2.0.4-ee`），可以直接在目标机器上用这份代码库的 `start.sh` 启动，不需要 `database/` 下的安装介质（那是构建镜像才需要的原始安装包）。目标机器要求：

- 同为 `linux/amd64` 架构，或者能跑 `linux/amd64` 模拟（如 Apple Silicon 上的 Docker Desktop）。
- Docker 版本能识别导出时的镜像格式，跨大版本 Docker 一般没问题，但差异过大（比如非常旧的 Docker）建议提前在测试环境验证一次。

## 启动容器

```bash
./start.sh
docker logs -f oracle11204
```

首次启动会自动执行 `dbca -silent -createDatabase`，根据机器性能和内存配置，整个过程可能需要几分钟到十几分钟，耐心跟着 `docker logs -f` 看进度，直到出现建库完成、监听器注册成功的日志。之后每次启动（`docker start`）都会走 `startup`，几十秒内完成。

容器已配置：

- `--network host`：容器直接使用宿主机网络栈，1521 端口对宿主机所有网络接口（`127.0.0.1` 及局域网 IP）都可达，不需要 `-p` 端口映射。
- `--restart unless-stopped`：容器异常退出会自动重启；主动 `docker stop`/`./stop.sh` 后不会自动拉起。
- `--stop-timeout 120`：给 `shutdown immediate` 留足关库时间。
- 数据默认以 `bind` 方式持久化在项目目录下的 `oracle_data`（即 `<project>/oracle_data`），挂载到容器内 `/u01/app/oracle/oradata`，包含数据文件、spfile、密码文件、闪回恢复区，可以直接在宿主机用 Finder/终端浏览。启动时会打印实际使用的挂载方式和路径（`Data mount: ...`）。

> **安全提醒**：`--network host` 意味着局域网内任何能访问这台机器的人都能连到 1521 端口。上线前务必把 `ORACLE_PWD` 改成强密码，不要用默认的 `Oracle_123`。如果只需要本机访问，可以把 `start.sh` 里的 `--network host` 改回 bridge 模式加 `-p 127.0.0.1:1521:1521`。

## 停止 / 重启

```bash
./stop.sh                      # 等价于 docker stop -t 120 oracle11204，触发 shutdown immediate
docker start oracle11204       # 重新启动，走 startup 而非重建
docker restart oracle11204
```

不要用 `docker kill` 或 `docker rm -f` 直接杀掉运行中的容器，会跳过 `shutdown immediate`，可能导致下次启动需要 instance recovery。

## 连接数据库

- Host：`127.0.0.1` 或本机局域网 IP
- Port：`1521`
- SID / Service：`ORCL`（即 `.env` 里的 `ORACLE_SID`）
- 用户：`system` 或 `sys as sysdba`
- 密码：`.env` 里的 `ORACLE_PWD`

JDBC（Service 方式）：

```text
jdbc:oracle:thin:@//<host>:1521/ORCL
```

从容器内部用 OS 认证连接（不需要密码）：

```bash
docker exec -it -u oracle oracle11204 bash -lc \
  'source /opt/oracle/env.sh; sqlplus / as sysdba'
```

从宿主机 sqlplus 客户端连接（需要密码）：

```bash
sqlplus system/<ORACLE_PWD>@//127.0.0.1:1521/ORCL
```

## 日常维护

### 查看状态

```bash
docker ps -a --filter name=oracle11204
docker inspect oracle11204 --format '{{.State.Health.Status}}'
docker logs --tail 200 oracle11204
```

### 查看 alert log

`run-oracle.sh` 启动后会自动 `tail -F` alert log 到容器标准输出，`docker logs -f` 就能看到。也可以直接进容器看：

```bash
docker exec -it oracle11204 bash -lc \
  'find $ORACLE_BASE/diag/rdbms -name "alert_*.log" -exec tail -n 200 {} \;'
```

### 备份

默认 `bind` 模式下数据就是普通目录，离线备份直接打包即可（容器需先停止以保证一致性；在线备份建议改用 RMAN）：

```bash
./stop.sh
tar -czf oracle_data-$(date +%Y%m%d).tar.gz -C oracle_data .
docker start oracle11204
```

如果用的是 `volume` 模式，备份需要借助一个临时容器挂载该 volume：

```bash
./stop.sh
docker run --rm -v oracle11204-data:/data -v "$PWD":/backup \
  alpine tar -czf /backup/oracle11204-data-$(date +%Y%m%d).tar.gz -C /data .
docker start oracle11204
```

更严谨的在线备份可以在容器内用 RMAN 对 `$ORACLE_DATA` 做增量备份，这里不展开。

### 修改内存 / SGA 大小

`ORACLE_MEMORY_MB` 只在**首次建库**时生效（写入 spfile）。修改 `.env` 后已存在的数据库不会自动生效，需要连进去手动改：

```sql
ALTER SYSTEM SET sga_target=XXXXM SCOPE=SPFILE;
ALTER SYSTEM SET sga_max_size=XXXXM SCOPE=SPFILE;
-- 之后 docker restart oracle11204 生效
```

### 彻底重建（清空数据）

```bash
./stop.sh
docker rm -f oracle11204
rm -rf oracle_data                  # bind 模式；volume 模式改成 docker volume rm oracle11204-data
./start.sh                          # 重新走一遍 dbca 建库
```

以上命令会清空所有数据，谨慎操作。

## 已知问题与注意点

- **`setpriv --init-groups` 不兼容**：基础镜像 `oraclelinux:7` 的 `util-linux` 版本较老，`setpriv` 不支持 `--init-groups`。`entrypoint.sh` / `healthcheck.sh` 里已改成显式 `--groups="$(id -G oracle | tr ' ' ',')"` 来降权，如果重写这两个脚本或者换了基础镜像，注意重新确认 `setpriv --help` 支持的参数。
- **闪回恢复区必须落在持久化卷内**：`run-oracle.sh` 的 `dbca` 命令里显式指定了 `-recoveryAreaDestination "$ORACLE_DATA/fast_recovery_area"`。如果去掉这个参数，恢复区会默认落在容器可写层，一旦 `docker rm` 删除容器（即使数据卷保留），下次用同一份数据卷启动会因为找不到恢复区目录报 `ORA-01261`/`ORA-01262`。
- **OS 认证依赖补充组**：容器内任何要执行 `sqlplus / as sysdba` 的进程，运行身份的补充组必须包含 `dba`，否则 OS 认证会失败。降权脚本传 `--groups` 时不能只传主 gid。
- **健康检查的建库期误报**：`dbca` 建库过程中，`HEALTHCHECK` 偶尔会在数据库还没建完时短暂返回 `healthy`（可能是 CREATE DATABASE 过程中实例短暂进入可查询的中间状态）。首次启动判断"建库是否真正完成"应以 `docker logs` 里的完整建库日志为准，不要只看 `docker ps` 的健康状态。
- **macOS + Apple Silicon**：`--platform linux/amd64` 意味着全程走模拟层，构建和建库都会明显慢于原生 Linux，属于预期行为。
- **`bind` 挂载在 macOS 上的 I/O 性能**：Docker Desktop 在 macOS 上通过一个 Linux 虚拟机运行容器，`bind` 挂载 Mac 本机目录需要经过文件共享层（gRPC-FUSE/VirtioFS），随机小文件读写（Oracle 数据文件的典型访问模式）会比 `volume` 慢。默认用 `bind` 是为了方便直接在宿主机浏览/备份数据文件；如果建库或查询感觉明显变慢，把 `.env` 里的 `DATA_MODE` 改成 `volume` 即可，数据会转存到 Docker 管理的 named volume 里（不能直接在 Mac 上浏览，但 I/O 更快）。
- **`--network host` 在 Docker Desktop for Mac 上的实际表现**：即使 Docker Desktop 设置里 `hostNetworkingEnabled` 为关闭，实测 `--network host` 仍然让容器端口在 `127.0.0.1` 和主机局域网 IP 上都可达，因为 Docker Desktop 的虚拟机网络转发和这个设置项不完全是一回事。如果对连通性有疑问，用 `nc -z <ip> 1521` 直接测。
- **容器时区已固定为 `Asia/Shanghai`**：运行时镜像在构建阶段写了 `/etc/localtime`/`/etc/timezone`（默认基础镜像 `oraclelinux:7` 是 UTC，跟宿主机差 8 小时）。容器 `date`、alert log 时间戳、`SYSDATE` 现在都跟宿主机一致；`DBTIMEZONE`（影响 `TIMESTAMP WITH TIME ZONE` 列）仍是 Oracle 建库时的默认值 `+00:00`，这是正常行为，不受这个修复影响。需要改成别的时区，构建时传 `--build-arg TZ_NAME=Xxx/Xxx`（`ARG` 只在 Dockerfile 里声明，`build.sh` 目前没有暴露对应的环境变量透传，要改就直接在 `build.sh` 的 `BUILD_ARGS` 里加 `--build-arg`）。
- **`build.sh` 里 `grep -q` 配合 `pipefail` 的陷阱**：早期版本写过 `unzip -l "$ZIP1" | grep -q ' database/runInstaller$'`，在 `set -o pipefail` 下，`grep -q` 一旦匹配会立刻关闭管道退出，导致 `unzip` 收到 `SIGPIPE` 提前终止（非零退出码），`pipefail` 因此把整条命令判定为失败——即使 `grep` 确实匹配到了。现在改成先把 `unzip -l` 的输出读入变量再 `grep`，绕开管道退出码问题。以后写类似的“列出很多东西再找一行”的校验逻辑，避免直接把大输出管道给 `grep -q`。

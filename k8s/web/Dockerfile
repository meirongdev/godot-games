# Godot Web 导出的静态托管镜像。
#
# 构建上下文是仓库根目录,且**必须先有 build/web/** —— 由 CI 跑
# tools/build_web.sh 生成(build/ 在 .gitignore 里,不进仓库)。
#
# 用 nginx-unprivileged:进程以 uid 101 运行、监听 8080,
# 配合 Deployment 的 runAsNonRoot 才成立。官方 nginx 镜像是 root + 80 端口。
FROM docker.io/nginxinc/nginx-unprivileged:1.29-alpine

USER root

COPY k8s/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web/ /usr/share/nginx/html/

# 断言 wasm 的 MIME 存在。缺了的话浏览器只会报一句含糊的 MIME 错误,
# 与其留到运行时排查,不如在这里构建失败。
RUN grep -q "application/wasm" /etc/nginx/mime.types \
    || (echo "✗ mime.types 里没有 application/wasm" && exit 1)

# 预压 gzip:38 MB 的 wasm 压到约 10 MB。gzip_static 会优先用 .gz。
# 保留原文件,给不支持 gzip 的客户端兜底。
RUN find /usr/share/nginx/html -type f \
        \( -name '*.wasm' -o -name '*.js' -o -name '*.html' -o -name '*.pck' \) \
        -exec gzip -9 -k {} \; \
    && chown -R 101:101 /usr/share/nginx/html

USER 101
EXPOSE 8080

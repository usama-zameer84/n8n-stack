# Custom n8n task runner — extends the official n8nio/runners image so Python
# Code nodes can import arbitrary third-party libraries.
#
# The official image ships a Python runner that executes through a dedicated
# virtualenv at /opt/runners/task-runner-python/.venv (Python 3.13). That venv
# only contains the runner's own runtime deps (websockets, urllib3, ...), so
# any library a Code node imports must be installed *into that venv* — a
# system-wide `pip install` is invisible to the runner process.
#
# To add libraries: edit ./requirements.txt, then `make build-runners`.
# `N8N_RUNNERS_EXTERNAL_ALLOW=*` (set in docker-compose.yml) lets Code nodes
# import anything installed here without per-module allowlisting.

FROM n8nio/runners:latest

# The venv is root-owned in the base image; install as root then drop back.
USER root

COPY requirements.txt /tmp/requirements.txt

RUN V=/opt/runners/task-runner-python/.venv \
 && $V/bin/python -m ensurepip --default-pip \
 && $V/bin/python -m pip install --no-cache-dir -r /tmp/requirements.txt

USER runner
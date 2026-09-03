#!/usr/bin/env bash
set -euo pipefail
workflow_build(){ workflow_all_tasks "$1"; }
workflow_resume(){ workflow_all_tasks_resume "$1"; }

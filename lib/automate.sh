# lib/automate.sh — auto-all is unattended apply (same pipeline_run).

cmd_auto_all() {
  UNLEASH_UNATTENDED=1
  pipeline_run
}

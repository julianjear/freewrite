#!/bin/bash
# Supervisor for the freewrite-coach LiveKit agent.
#
# The agent is a long-lived worker; ad-hoc `nohup python agent.py dev` kept
# dying when the launching shell/session was reaped. This script restarts it
# on exit and logs to a stable path, and survives its parent via nohup+disown:
#
#   ./run-agent.sh            # start supervised (detached)
#   ./run-agent.sh stop       # stop supervisor + agent
#   ./run-agent.sh status     # is it running?
#   tail -f /tmp/freewrite-coach.log
#
# For a permanently-on setup use launchd or deploy to LiveKit Cloud
# (`lk agent create` / `deploy`) per README.md — this script is the local-dev
# middle ground.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/freewrite-coach.log
PIDFILE=/tmp/freewrite-coach.supervisor.pid

case "${1:-start}" in
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE"
    pkill -f "agent.py dev" 2>/dev/null
    echo "stopped"
    ;;
  status)
    if pgrep -f "agent.py dev" >/dev/null; then
      echo "agent RUNNING (log: $LOG)"
    else
      echo "agent NOT running"
    fi
    ;;
  _supervise)
    echo $$ > "$PIDFILE"
    while true; do
      echo "[supervisor] starting agent $(date)" >> "$LOG"
      cd "$DIR" && "$DIR/.venv/bin/python" agent.py dev >> "$LOG" 2>&1
      echo "[supervisor] agent exited ($?) — restarting in 3s" >> "$LOG"
      sleep 3
    done
    ;;
  start|*)
    # The launchd LaunchAgent (ai.julian.freewrite-coach) normally owns the
    # agent. Refuse to double-serve dispatches alongside it.
    if launchctl print "gui/$(id -u)/ai.julian.freewrite-coach" >/dev/null 2>&1; then
      echo "LaunchAgent ai.julian.freewrite-coach is loaded — it owns the agent."
      echo "Use: launchctl kickstart -k gui/\$UID/ai.julian.freewrite-coach"
      exit 0
    fi
    if pgrep -f "agent.py dev" >/dev/null; then
      echo "already running (log: $LOG)"; exit 0
    fi
    nohup "$DIR/run-agent.sh" _supervise >/dev/null 2>&1 &
    disown
    echo "supervised agent starting (log: $LOG)"
    ;;
esac

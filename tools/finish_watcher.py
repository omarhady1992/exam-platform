#!/usr/bin/env python3
"""Poll finish_notifications and print Study Mentor wake payloads. No email to Mentor."""
import json, os, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from exam_cli import rpc, CliError  # noqa: E402

STUDY_MENTOR_ID = "3d64d246-e9e6-4f1b-b729-a36bf85b0a7f"
INTERVAL = int(os.environ.get("FINISH_POLL_SECONDS", "180"))

def payload(n):
    return {
        "send_to_agent": STUDY_MENTOR_ID,
        "priority": True,
        "exam_slug": n["exam_slug"],
        "student_email": n.get("student_email"),
        "attempt_id": n["attempt_id"],
        "pending_manual": n.get("pending_manual"),
        "finish_id": n["id"],
        "commands": n.get("commands"),
        "message": (
            f"Exam finished: {n['exam_slug']} by {n.get('student_email')} "
            f"(attempt {n['attempt_id']}, pending_manual={n.get('pending_manual')}). "
            f"Run: bin/exam export {n['exam_slug']}; "
            f"bin/exam mark {n['exam_slug']} --file …; "
            f"bin/exam release {n['exam_slug']} --attempt {n['attempt_id']}; "
            f"then bin/exam ack --id {n['id']}"
        ),
    }

def main():
    seen = set()
    once = "--once" in sys.argv
    while True:
        try:
            rows = rpc("admin_list_finishes", p_unacked_only=True) or []
        except CliError as e:
            print("error:", e, file=sys.stderr); return 1
        for n in rows:
            if n["id"] in seen:
                continue
            seen.add(n["id"])
            print(json.dumps(payload(n), indent=2, ensure_ascii=False), flush=True)
        if once:
            return 0
        time.sleep(INTERVAL)

if __name__ == "__main__":
    raise SystemExit(main())

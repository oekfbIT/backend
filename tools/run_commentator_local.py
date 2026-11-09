#!/usr/bin/env python3
"""Run the built API against a loopback-only commentary test database, never production."""
import argparse
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", help="Model supporting strict Structured Outputs; otherwise use COMMENTATOR_AI_MODEL")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--mongo-port", type=int, default=27029)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    env_file = root / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            if name == "OPENAI_API_KEY" or name.startswith("COMMENTATOR_"):
                os.environ.setdefault(name, value.strip().strip('"').strip("'"))
    model = args.model or os.environ.get("COMMENTATOR_AI_MODEL")
    if not model:
        parser.error("Set COMMENTATOR_AI_MODEL or pass --model.")
    if not os.environ.get("OPENAI_API_KEY") and not os.environ.get("COMMENTATOR_AI_API_KEY"):
        parser.error("Fill OPENAI_API_KEY in the ignored .env file.")
    if not 1 <= args.port <= 65535 or not 1 <= args.mongo_port <= 65535:
        parser.error("Ports must be between 1 and 65535.")
    executable = root / ".build/debug/App"
    if not executable.exists():
        parser.error("Build the backend first with swift build.")
    os.environ["CONNECTION_STRING"] = f"mongodb://127.0.0.1:{args.mongo_port}/oekfb_commentator_local"
    os.environ["COMMENTATOR_ENABLED"] = "true"
    os.environ["COMMENTATOR_AI_MODEL"] = model
    os.environ["GA4_ENABLED"] = "false"
    os.environ["PORT"] = str(args.port)
    print(f"Local API: http://127.0.0.1:{args.port}; isolated MongoDB port {args.mongo_port}; model {model}", flush=True)
    os.execv(str(executable), ["App", "serve", "--env", "development", "--hostname", "127.0.0.1", "--port", str(args.port)])


if __name__ == "__main__":
    main()

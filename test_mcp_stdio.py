#!/usr/bin/env python3
import subprocess
import json
import time
import sys

def main():
    binary_path = "./.build/release/AIChalkboard.app/Contents/MacOS/AIChalkboard"
    print(f"Launching MCP process: {binary_path}")
    
    proc = subprocess.Popen(
        [binary_path, "--mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        bufsize=1
    )

    def send_request(req):
        payload = json.dumps(req) + "\n"
        proc.stdin.write(payload)
        proc.stdin.flush()
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("Process closed stdout unexpectedly.")
        return json.loads(line)

    print("\n1. Testing 'initialize'...")
    init_res = send_request({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "1.0"}
        }
    })
    print("Initialize response:", json.dumps(init_res, indent=2))

    print("\n2. Testing 'tools/list'...")
    list_res = send_request({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list"
    })
    tools = [t["name"] for t in list_res["result"]["tools"]]
    print("Available tools:", tools)
    assert "draw_path" in tools

    print("\n3. Testing 'draw_path' for freehand organic circle...")
    path_res = send_request({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "draw_path",
            "arguments": {
                "points": [
                    [400, 300], [420, 295], [450, 310], [445, 340], [410, 350], [390, 320], [400, 300]
                ],
                "color": "#FF9500",
                "stroke_width": 4.0,
                "is_closed": True,
                "label": "Freehand Circle Spot"
            }
        }
    })
    print("draw_path response:", path_res["result"]["content"][0]["text"])

    print("\n4. Testing 'list_annotations'...")
    ann_res = send_request({
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {
            "name": "list_annotations",
            "arguments": {}
        }
    })
    print("list_annotations response:", ann_res["result"]["content"][0]["text"])

    print("\nAll freehand draw_path MCP tests PASSED successfully!")
    proc.terminate()

if __name__ == "__main__":
    main()

import json, subprocess, sys

data = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                 capture_output=True, text=True, check=True).stdout)
for runtime, devices in sorted(data["devices"].items(), reverse=True):
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)
print("no simulator", file=sys.stderr)
sys.exit(1)

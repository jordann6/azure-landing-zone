#!/usr/bin/env python3
"""Remove this landing zone's billed gallery versions after compute teardown."""
import json
import os
import subprocess


def query(*args):
    result = subprocess.run(["az", *args, "-o", "json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    group = f"rg-{os.environ.get('PROJECT', 'alz')}-images"
    for gallery in query("sig", "list"):
        if gallery["resourceGroup"].lower() != group.lower():
            continue
        name = gallery["name"]
        for image in query("sig", "image-definition", "list", "-g", group, "--gallery-name", name):
            for version in query("sig", "image-version", "list", "-g", group,
                                 "--gallery-name", name, "--gallery-image-definition", image["name"]):
                print(f"Removing billed gallery version: {name}/{image['name']}/{version['name']}", flush=True)
                subprocess.run(["az", "sig", "image-version", "delete", "--ids", version["id"]], check=True)


if __name__ == "__main__":
    main()

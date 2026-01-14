#!/usr/bin/env python3
import os
import sys
import json
import urllib.request
import urllib.parse
import urllib.error

# gh_release.py - The Supply Line
# Manages GitHub Releases and Asset Uploads.

def request(url, token, method="GET", data=None, content_type="application/vnd.github+json"):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    if content_type:
        req.add_header("Content-Type", content_type)
    return urllib.request.urlopen(req)

def get_or_create_release(owner, repo, tag, token):
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    
    # Try getting existing release
    try:
        with request(f"{api_base}/releases/tags/{tag}", token) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    
    # Create if not exists
    print(f"Release {tag} not found, creating...")
    payload = json.dumps({
        "tag_name": tag,
        "name": tag,
        "body": "Auto-published by God Mode CI",
        "draft": False,
        "prerelease": False,
    }).encode("utf-8")
    
    with request(f"{api_base}/releases", token, method="POST", data=payload) as resp:
        return json.load(resp)

def get_release_assets(owner, repo, release_id, token):
    api_base = f"https://api.github.com/repos/{owner}/{repo}"
    assets = {}
    page = 1
    while True:
        url = f"{api_base}/releases/{release_id}/assets?per_page=100&page={page}"
        with request(url, token) as resp:
            data = json.load(resp)
        if not data:
            break
        for asset in data:
            assets[asset["name"]] = asset["id"]
        page += 1
    return assets

def delete_asset(owner, repo, asset_id, token):
    url = f"https://api.github.com/repos/{owner}/{repo}/releases/assets/{asset_id}"
    request(url, token, method="DELETE")

def upload_asset(upload_url_template, file_path, token):
    name = os.path.basename(file_path)
    print(f"Uploading {name}...")
    
    with open(file_path, "rb") as f:
        file_data = f.read()
    
    encoded_name = urllib.parse.quote(name)
    upload_url = upload_url_template.split("{")[0] + f"?name={encoded_name}"
    
    request(upload_url, token, method="POST", data=file_data, content_type="application/octet-stream")

def main():
    if len(sys.argv) < 5:
        print("Usage: gh_release.py <owner> <repo> <tag> <token> <file1> [file2...]")
        sys.exit(1)

    owner, repo, tag, token = sys.argv[1:5]
    files = sys.argv[5:]

    try:
        release = get_or_create_release(owner, repo, tag, token)
        release_id = release["id"]
        upload_url_template = release["upload_url"]
        
        existing_assets = get_release_assets(owner, repo, release_id, token)
        
        for file_path in files:
            name = os.path.basename(file_path)
            if name in existing_assets:
                print(f"Deleting existing asset: {name}")
                delete_asset(owner, repo, existing_assets[name], token)
            
            upload_asset(upload_url_template, file_path, token)
            
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()

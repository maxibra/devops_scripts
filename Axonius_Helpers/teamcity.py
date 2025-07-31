# aws secretsmanager get-secret-value --secret-id ax-builds/builds-secrets  --query 'SecretString' --output text --profile ${p} --region ${r} > /tmp/s.json; 
# aws secretsmanager get-secret-value --secret-id axonius-release-manager-client-token  --query 'SecretString' --output text --profile ${p} --region ${r} > /tmp/t.json; 
# url='https://teamcity.in.axonius.com'; 
# headers="-H 'CF-Access-Client-Id: $(jq -r '.client_id' /tmp/t.json)' \
#         -H 'CF-Access-Client-Secret: $(jq -r '.client_secret' /tmp/t.json)' \
#         -H 'X-TC-CSRF-Token: 73cca6f2-71cc-46f4-8a93-921e32d5ee4f'"; 
# curl -L -u "$(jq -r '.teamcity.data.username' /tmp/s.json):$(jq -r '.teamcity.data.password' /tmp/s.json)" ${headers} \
#     "${url}/app/rest/buildTypes/id:Exports_Cloud";
# rm /tmp/s.json /tmp/t.json

import boto3
import click
import json
import logging
import os
import requests
from urllib.parse import urljoin
import sys

from pprint import pprint

# requests.packages.urllib3.disable_warnings()

logger = logging.getLogger(__name__)


# Configuration
TEAMCITY_URL = "https://teamcity.in.axonius.com"  # Replace with your TeamCity server URL
USERNAME = "<your-username>"               # Replace with your username or use token
PASSWORD = "<your-password>"               # Replace with your password or leave empty if using token
TOKEN = "<your-access-token>"             # Replace with your token if not using username/password
OUTPUT_DIR = "teamcity_scripts"           # Directory to save scripts

# Set up authentication
auth = None
if TOKEN:
    headers = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"}
else:
    auth = (USERNAME, PASSWORD)
    headers = {"Accept": "application/json"}

# Ensure output directory exists
os.makedirs(OUTPUT_DIR, exist_ok=True)


def get_tc_creds(secret_name: str, profile_name: str, region_name="us-east-2") -> dict:
    """Fetch secret from AWS Secrets Manager."""
    session = boto3.Session(profile_name=profile_name, region_name=region_name)
    client = session.client(service_name="secretsmanager")
    try:
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
        secret = get_secret_value_response["SecretString"]
        return json.loads(secret)
    except Exception as e:
        print(f"Error fetching secret {secret_name}: {e}")
        return None

def fetch_json(tc_url: str, endpoint: str, headers: dict = None, auth: tuple = None) -> dict:
    """Fetch JSON data from TeamCity REST API."""
    url = urljoin(tc_url, f"/app/rest/{endpoint}.json")
    try:
        response = requests.get(url, headers=headers, auth=auth)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"Error fetching {url}: {e}")
        return None

def save_script(project_id, build_type_id, step_id, script_content, script_type):
    """Save script content to a file."""
    # Determine file extension based on script type
    extension = {
        "commandLine": ".bat",
        "powershell": ".ps1",
        "shell": ".sh"
    }.get(script_type, ".txt")

    # Create directory structure: OUTPUT_DIR/project_id/build_type_id/
    project_dir = os.path.join(OUTPUT_DIR, project_id)
    build_dir = os.path.join(project_dir, build_type_id)
    os.makedirs(build_dir, exist_ok=True)

    # Save script to file
    script_filename = os.path.join(build_dir, f"step_{step_id}{extension}")
    try:
        with open(script_filename, "w", encoding="utf-8") as f:
            f.write(script_content)
        print(f"Saved script: {script_filename}")
    except IOError as e:
        print(f"Error saving script {script_filename}: {e}")


class TeamCityHandler():
    """Handler for TeamCity API interactions and build management operations."""

    def __init__(self, url: str = None, tc_username: str = None, tc_password: str = None):
        self._url = url
        self._tc_username = tc_username
        self._tc_password = tc_password
        self._client = self._initialize_client()

    def _initialize_client(self) -> requests.Session:
        """Initialize the HTTP client with authentication and verification settings."""
        client = requests.session()
        client.verify = True
        client.auth = (self._tc_username, self._tc_password)

        print("CSRF")
        csrf_token = self._get_csrf_token(client)

        client.headers.update({
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-TC-CSRF-Token': csrf_token
        })
        print("before returning client")
        return client

    def _get_csrf_token(self, client: requests.Session) -> str:
        """Retrieve CSRF token from TeamCity."""
        try:
            response = client.get(f'{self._url}/authenticationTest.html?csrf')
            response.raise_for_status()
            pprint(f"CSRF token response: {response.text}")
            return response.text
        except requests.RequestException as e:
            logger.error(f"Failed to retrieve CSRF token: {e}")
            return ""


@click.command()
@click.option('--profile', required=True, help='AWS profile name for secrets manager')
@click.option('--region', default='us-east-2', show_default=True, help='AWS region for secrets manager')
@click.option('--secret-name', default='ax-builds/builds-secrets', show_default=True, help='AWS secret name for TeamCity credentials')
@click.option('--teamcity-url', required=True, help='TeamCity server URL')
@click.option('--token', default=None, help='TeamCity access token (optional, overrides username/password)')
@click.option('--output-dir', default='teamcity_scripts', show_default=True, help='Directory to save scripts')
def main(profile, region, secret_name, teamcity_url, token, output_dir):
    global TEAMCITY_URL, TOKEN, OUTPUT_DIR, auth, headers
    TEAMCITY_URL = teamcity_url
    TOKEN = token
    OUTPUT_DIR = output_dir
    
    tc_creds = get_tc_creds(secret_name, profile, region)
    # tc = TeamCityHandler(
    #     url=TEAMCITY_URL,
    #     tc_username=tc_creds.get("tc_user_name"),
    #     tc_password=tc_creds.get("tc_user_pwd")
    # )

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Step 1: Fetch all projects
    projects_data = fetch_json("projects")
    if not projects_data or "project" not in projects_data:
        print("Failed to fetch projects.")
        sys.exit(1)

    # Step 2: Iterate through each project
    for project in projects_data["project"]:
        project_id = project["id"]
        project_name = project["name"]
        print(f"Processing project: {project_name} ({project_id})")

        # Skip the root project (_Root)
        if project_id == "_Root":
            continue

        # Step 3: Fetch build configurations for the project
        build_types_data = fetch_json(f"projects/id:{project_id}/buildTypes")
        if not build_types_data or "buildType" not in build_types_data:
            print(f"No build configurations found for project {project_name}")
            continue

        # Step 4: Iterate through each build configuration
        for build_type in build_types_data["buildType"]:
            build_type_id = build_type["id"]
            build_type_name = build_type["name"]
            print(f"  Processing build configuration: {build_type_name} ({build_type_id})")

            # Step 5: Fetch build steps for the build configuration
            steps_data = fetch_json(f"buildTypes/id:{build_type_id}/steps")
            if not steps_data or "step" not in steps_data:
                print(f"    No steps found for build configuration {build_type_name}")
                continue

            # Step 6: Process each build step
            for step in steps_data["step"]:
                step_id = step["id"]
                step_type = step.get("type", "unknown")
                step_name = step.get("name", step_id)

                # Check if the step contains a script (e.g., commandLine, powershell, shell)
                if step_type in ["commandLine", "powershell", "shell"]:
                    script_content = step.get("properties", {}).get("property", [])
                    script_text = None
                    for prop in script_content:
                        if prop.get("name") in ["script.content", "script"]:
                            script_text = prop.get("value")
                            break

                    if script_text:
                        print(f"    Found script in step: {step_name} (type: {step_type})")
                        save_script(project_id, build_type_id, step_id, script_text, step_type)
                    else:
                        print(f"    No script content found in step: {step_name}")
                else:
                    print(f"    Skipping non-script step: {step_name} (type: {step_type})")

if __name__ == "__main__":
    # main()
    tc = TeamCityHandler('https://tc-int-lb.axonius.com')
    # tc_url = "https://tc-int-lb.axonius.com"
    # # tc_creds = get_tc_creds("axonius-teamcity-api-user", "139388023521:admin", "us-east-2")
    # tc_creds = get_tc_creds("ax-builds/builds-secrets", "139388023521:admin", "us-east-2")
    # pprint(tc_creds)
    # headers = {
    #     'Content-Type': 'application/json',
    #     'Accept': 'application/json'
    # }
    # auth = (tc_creds.get("teamcity.data.username"), tc_creds.get("teamcity.data.password"))
    # auth = (tc_creds.get('teamcity', {}).get('data', {}).get('username'),
    #         tc_creds.get('teamcity', {}).get('data', {}).get('password'))
    # pprint(fetch_json(tc_url, "projects", headers=headers, auth=auth))
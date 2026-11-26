"""Render app and Share Extension signing options without reading credentials."""
import os
from pathlib import Path
import plistlib
import sys

data = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
data["teamID"] = os.environ["TEAM_ID"]
app_id = os.environ.get("APP_ID", "com.hgsldswk.voicemailkeeper")
data["provisioningProfiles"] = {
    app_id: os.environ.get("APP_PROFILE", "VoicemailKeeper AppStore"),
    app_id + ".share": os.environ.get("SHARE_PROFILE", "VoicemailKeeper Share AppStore"),
}
sys.stdout.buffer.write(plistlib.dumps(data))

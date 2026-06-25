# jfm.sh
bash scripts for interacting with jellyfin servers
# Jellyfin Download Manager
A bash script for managing Jellyfin media downloads across multiple servers.
## Setup
### 1. Clone the Repository
```bashgit clone <your-repo-url>cd <your-repo-name>
```
2. Create Your Configuration File

Copy the example configuration:
bash

cp config.example.sh config.sh

3. Edit config.sh with Your Credentials

Open config.sh in your text editor and fill in your actual Jellyfin server URLs and API keys:
bash

vi config.sh

Example:
declare -A JELLYFIN_SERVERS=(  [server1]="https://jellyfin.example.com"  [server2]="https://jellyfin2.example.com")
declare -A JELLYFIN_KEYS=(  [server1]="your-api-key-here"  [server2]="your-api-key-here")
# Download location
DOWNLOAD_BASE="/data/video"

4. Run the Script
./jellyfin.sh

Configuration
Getting Your Jellyfin API Key

    Log in to your Jellyfin server
    Right Click on any single video
    Choose Copy Stream URL
    The value after ?api_key= is your API key.

Files

    jellyfin.sh — Main script
    Parameters:
      -play partial video/series name
        searches the words in the partial name and plays the closest match
      -search partial video/series name
        returns titles and video ids
      [video/series id]
        downloads that id, if series then adds to database for future polling
        the database is plaintext in ${HOME}/.jellyfin_status.txt, add # to comment out a series and prevent future polling (also removes from playing)
      -poll 
        polls series for additional episodes

    config.example.sh — Configuration template

Requirements
    wget
    curl
    jq

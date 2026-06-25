#!/bin/bash
# JELLYFIN SERVER CONFIGURATION TEMPLATE
# Copy this file to config.sh and fill in your actual values
# DO NOT commit config.sh to version control

declare -A JELLYFIN_SERVERS=(
  [server1]="https://jellyfin.example.com"
  [server2]="https://jellyfin2.example.com"
)

declare -A JELLYFIN_KEYS=(
  [server1]="your-api-key-here"
  [server2]="your-api-key-here"
)

# Download location
DOWNLOAD_BASE="/data/video"

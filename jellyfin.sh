#!/bin/bash
#set -x

# Source configuration
if [[ ! -f "$(dirname "$0")/config.sh" ]]; then
  echo "Error: config.sh not found. Please run: cp config.example.sh config.sh"
  exit 1
fi
source "$(dirname "$0")/config.sh"

# Status database file
# Format: name|id|server_key|type|download_timestamp|last_watched_timestamp|watched_status
# For series: last_watched_timestamp is last overall watch, watched_status can track last_episode
JELLYFIN_STATUS="${HOME}/.jellyfin_status.txt"

# Function: Check item type on a specific server
check_item_type() {
  local item_id="$1"
  local server_key="$2"
  local server="${JELLYFIN_SERVERS[$server_key]}"
  local api_key="${JELLYFIN_KEYS[$server_key]}"
  if result=$(curl -s "$server/Items?ids=$item_id&api_key=$api_key"); then
    echo "$result" | jq -r '.Items[0].Type // "Unknown"'
  else
    echo "Error"
  fi
}

# Function: Fetch item details
get_item_details() {
  local item_id="$1"
  local server_key="$2"
  local server="${JELLYFIN_SERVERS[$server_key]}"
  local api_key="${JELLYFIN_KEYS[$server_key]}"
  
  curl -s "$server/Items?ids=$item_id&api_key=$api_key"
}

# Function: Register item in database
register_item() {
  local name="$1"
  local id="$2"
  local server_key="$3"
  local type="$4"
  
  if ! grep -q "^$name|$id|" "$JELLYFIN_STATUS" 2>/dev/null; then
    now=$(date +%s)
    echo "$name|$id|$server_key|$type|$now|0|0" >> "$JELLYFIN_STATUS"
    echo "Registered $type: $name"
  fi
}

# Function: Update watched status
mark_watched() {
  local name="$1"
  local episode_info="$2"  # For series: "S01E05" format, for movies: "0"
  
  local now=$(date +%s)
  local temp_file="${JELLYFIN_STATUS}.tmp"
  
  while IFS= read -r line; do
    # Preserve comment lines exactly as-is
    if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
      echo "$line"
      continue
    fi
    
    # Parse the line only if it's not a comment
    IFS='|' read -r db_name id server_key type dl_ts last_watch watched <<< "$line"
    
    if [[ "$db_name" = "$name" ]]; then
      if [[ "$type" = "Series" ]]; then
        echo "$db_name|$id|$server_key|$type|$dl_ts|$now|$episode_info"
      else
        echo "$db_name|$id|$server_key|$type|$dl_ts|$now|1"
      fi
    else
      echo "$db_name|$id|$server_key|$type|$dl_ts|$last_watch|$watched"
    fi
  done < "$JELLYFIN_STATUS" > "$temp_file"
  
  mv "$temp_file" "$JELLYFIN_STATUS"
}

# Function: Download a movie
download_movie() {
  local item_id="$1"
  local server_key="$2"
  local item_data="$3"
  
  local server="${JELLYFIN_SERVERS[$server_key]}"
  local api_key="${JELLYFIN_KEYS[$server_key]}"
  local name=$(echo "$item_data" | jq -r '.Items[0].Name // "Unknown"')
  local year=$(echo "$item_data" | jq -r '.Items[0].ProductionYear // ""')
  local filename="${name}"
  
  if [[ -n "$year" ]]; then
    filename="${filename} ($year)"
  fi
  filename="${filename}.mp4"
  
  download_dir="$DOWNLOAD_BASE/Movies"
  mkdir -p "$download_dir"
  
  filepath="$download_dir/$filename"
  echo "  Downloading: $filename from $server_key"
  wget --show-progress--progress=bar:noscroll -qcO "$filepath" "$server/Items/$item_id/Download?api_key=$api_key"
  
  # Register in database
  register_item "$name" "$item_id" "$server_key" "Movie"
}

# Function: Download series episodes
download_series() {
  local series_id="$1"
  local server_key="$2"
  local item_data="$3"
  
  local server="${JELLYFIN_SERVERS[$server_key]}"
  local api_key="${JELLYFIN_KEYS[$server_key]}"
  local series_name=$(echo "$item_data" | jq -r '.Items[0].Name // "Unknown"' | tr ' ' '_')
  
  download_dir="$DOWNLOAD_BASE/$series_name"
  mkdir -p "$download_dir"
  
  # Fetch episodes
  if result=$(wget -qO- "$server/Shows/$series_id/Episodes?api_key=$api_key"); then
    total=$(echo "$result" | jq -r '.TotalRecordCount // 0')
    
    echo "Downloading $series_name ($total episodes) from $server_key..."
    
    for ((i = 0; i < total; i++)); do
      season=$(echo "$result" | jq -r ".Items[$i].ParentIndexNumber // 0")
      episode=$(echo "$result" | jq -r ".Items[$i].IndexNumber // 0")
      episode_name=$(echo "$result" | jq -r ".Items[$i].Name // \"Episode\"" | tr ' ' '_')
      episode_id=$(echo "$result" | jq -r ".Items[$i].Id")
      premiere=$(echo "$result" | jq -r ".Items[$i].PremiereDate // \"\"")
      
      filename="${series_name}_S${season}E${episode}_${episode_name}.mp4"
      filepath="$download_dir/$filename"
      
      echo "  Downloading: $filename"
      wget --show-progress--progress=bar:noscroll -qcO "$filepath" "$server/Items/$episode_id/Download?api_key=$api_key"
      
      if [[ -n "$premiere" ]]; then
        touch -d "$premiere" "$filepath"
      fi
    done
    
    # Register series in database
    register_item "$series_name" "$series_id" "$server_key" "Series"
  fi
}

# Function: Play a video with smart search
play_video() {
  local search_string="$1"
  
  if [[ ! -f "$JELLYFIN_STATUS" ]]; then
    echo "No items in database yet."
    return 1
  fi
  
  # Split search string into words
  local -a search_words=($search_string)
  local best_match=""
  local best_score=0
  local best_timestamp=0
  local best_type=""
  local best_watched=""
  
  # Score each entry
  while IFS='|' read -r name id server_key type dl_ts last_watch watched; do
    [[ "$name" =~ ^#|^$ ]] && continue
    
    # Count matching words (case-insensitive)
    local score=0
    local name_lower="${name,,}"
    for word in "${search_words[@]}"; do
      if [[ "$name_lower" =~ ${word,,} ]]; then
        ((score++))
      fi
    done
    
    # Skip if no matches
    [[ $score -eq 0 ]] && continue
    
    # Tie-breaking logic
    local use_this=0
    if [[ $score -gt $best_score ]]; then
      # Better score wins
      use_this=1
    elif [[ $score -eq $best_score ]]; then
      # Same score: prefer unwatched items by download date (most recent)
      if [[ "$watched" = "0" && "$last_watch" = "0" ]]; then
        if [[ $dl_ts -gt $best_timestamp ]]; then
          use_this=1
        fi
      elif [[ "$watched" != "0" || "$last_watch" != "0" ]]; then
        # Both watched, use oldest watch date
        if [[ $last_watch -lt $best_timestamp ]]; then
          use_this=1
        fi
      fi
    fi
    
    if [[ $use_this -eq 1 ]]; then
      best_match="$name"
      best_score=$score
      best_timestamp=$last_watch
      best_type="$type"
      best_watched="$watched"
      best_server_key="$server_key"
      best_id="$id"
      best_dl_ts="$dl_ts"
    fi
  done < "$JELLYFIN_STATUS"
  
  if [[ -z "$best_match" ]]; then
    echo "No matching items found for: $search_string"
    return 1
  fi
  
  echo "Found: $best_match (Type: $best_type)"
  
  # Determine which file to play
  if [[ "$best_type" = "Movie" ]]; then
    # Find the movie file
    local movie_file=$(find "$DOWNLOAD_BASE/Movies" -name "*${best_match}*" -type f 2>/dev/null | head -1)
    if [[ -z "$movie_file" ]]; then
      echo "Movie file not found for: $best_match"
      return 1
    fi
    echo "Playing: $movie_file"
    mpv --autofit=3072x1728 --autosync=5 --mc=0 --vo=gpu "$movie_file" &
    mark_watched "$best_match" "0"
    
elif [[ "$best_type" = "Series" ]]; then
    # Parse last watched episode from the watched field
    local current_season=1
    local current_episode=0
    
    if [[ "$best_watched" != "0" && "$best_watched" =~ ^[Ss]([0-9]+)[Ee]([0-9]+)$ ]]; then
      current_season="${BASH_REMATCH[1]}"
      current_episode="${BASH_REMATCH[2]}"
    fi
    
    local series_dir="$DOWNLOAD_BASE/${best_match}"
    local episode_file=""
    local next_season=""
    local next_episode=""
    
    # Function to find next episode in a given season
    find_next_episode_in_season() {
      local season="$1"
      local after_episode="$2"
      local search_dir="$3"
      
      local -a episodes=()
      
      # Find all episodes in this season (case-insensitive)
      while IFS= read -r file; do
        if [[ "$file" =~ [Ss]${season}[Ee]([0-9]+) ]]; then
          local ep_num="${BASH_REMATCH[1]}"
          episodes+=("$ep_num|$file")
        fi
      done < <(find "$search_dir" -type f -name "*.mp4" 2>/dev/null)
      
      # If no episodes found in this season, return empty
      if [[ ${#episodes[@]} -eq 0 ]]; then
        return 1
      fi
      
      # Sort episodes numerically
      local -a sorted
      while IFS= read -r entry; do
        sorted+=("$entry")
      done < <(printf '%s\n' "${episodes[@]}" | sort -t'|' -k1 -n)
      
      # Find first episode after the given one
      for entry in "${sorted[@]}"; do
        local ep_num="${entry%%|*}"
        local ep_file="${entry#*|}"
        
        if [[ $ep_num -gt $after_episode ]]; then
          echo "$ep_file"
          return 0
        fi
      done
      
      return 1
    }
    
    # Try current season first
    episode_file=$(find_next_episode_in_season "$current_season" "$current_episode" "$series_dir")
    
    # If not found in current season, try next season starting from episode -1 (so first episode is selected)
    if [[ -z "$episode_file" ]]; then
      current_season=$((current_season + 1))
      episode_file=$(find_next_episode_in_season "$current_season" "-1" "$series_dir")
    fi
    
    if [[ -z "$episode_file" ]]; then
      echo "No next episode found for: $best_match"
      return 1
    fi
    
    # Extract season and episode from the found file (case-insensitive)
    if [[ "$episode_file" =~ [Ss]([0-9]+)[Ee]([0-9]+) ]]; then
      next_season="${BASH_REMATCH[1]}"
      next_episode="${BASH_REMATCH[2]}"
    fi
    
    echo "Playing: $episode_file"
    mpv --autofit=3072x1728 --autosync=5 --mc=0 --vo=gpu "$episode_file" &
    mark_watched "$best_match" "S${next_season}E${next_episode}"
  fi


# Initialize database if needed
init_database() {
  if [[ ! -f "$JELLYFIN_STATUS" ]]; then
    echo "# Jellyfin Status Database" > "$JELLYFIN_STATUS"
    echo "# Format: name|id|server_key|type|download_timestamp|last_watched_timestamp|watched_status" >> "$JELLYFIN_STATUS"
    echo "# Types: Movie, Series" >> "$JELLYFIN_STATUS"
    echo "# watched_status: 1 for movies (watched/unwatched), S##E## for series (last episode watched)" >> "$JELLYFIN_STATUS"
  fi
}

if [[ -z "$1" ]]; then
  echo "Usage: $0 -search search string | -poll | -play search string | <item_id> [server_key]"
  echo "Available servers: ${!JELLYFIN_SERVERS[@]}"
  exit 1
fi

init_database

elif [[ "$1" = "-play" ]]; then
  shift
  play_video "$*"

elif [[ "$1" = "-poll" ]]; then
  echo "Checking for updates across all tracked series..."
  echo "---"

  update_count=0

  while IFS='|' read -r name id server_key type dl_ts last_watch watched; do
    [[ "$name" =~ ^#|^$ ]] && continue
    
    # Only poll series
    [[ "$type" != "Series" ]] && continue
    
    server="${JELLYFIN_SERVERS[$server_key]}"
    api_key="${JELLYFIN_KEYS[$server_key]}"
    download_dir="$DOWNLOAD_BASE/$name"
    
    echo "Checking: $name (ID: $id, Server: $server_key)"
    
    if result=$(wget -qO- "$server/Shows/$id/Episodes?api_key=$api_key"); then
      total=$(echo "$result" | jq -r '.TotalRecordCount // 0')
      
      for ((i = 0; i < total; i++)); do
        episode_id=$(echo "$result" | jq -r ".Items[$i].Id")
        season=$(echo "$result" | jq -r ".Items[$i].ParentIndexNumber // 0")
        episode=$(echo "$result" | jq -r ".Items[$i].IndexNumber // 0")
        episode_name=$(echo "$result" | jq -r ".Items[$i].Name // \"Episode\"" | tr ' ' '_')
        premiere=$(echo "$result" | jq -r ".Items[$i].PremiereDate // \"\"")
        
        filename="${name}_S${season}E${episode}_${episode_name}.mp4"
        filepath="$download_dir/$filename"
        
        if [[ ! -f "$filepath" ]]; then
          echo "  [NEW] Downloading: $filename"
          mkdir -p "$download_dir"
          wget --show-progress--progress=bar:noscroll -qcO "$filepath" "$server/Items/$episode_id/Download?api_key=$api_key"
          
          if [[ -n "$premiere" ]]; then
            touch -d "$premiere" "$filepath"
          fi
          
          ((update_count++))
        fi
      done
      echo "  ✓ Up to date ($total episodes)"
    else
      echo "  ✗ Error fetching from $server_key"
    fi
    
    echo ""
  done < "$JELLYFIN_STATUS"

  if [[ $update_count -gt 0 ]]; then
    echo "---"
    echo "Downloaded $update_count new episode(s)"
  else
    echo "No new episodes found"
  fi

else
  item_id="$1"
  server_key="${2}"

  # Try servers in order if not specified
  if [[ -z "$server_key" ]]; then
    attempted_servers=("${!JELLYFIN_SERVERS[@]}")
  else
    attempted_servers=("$server_key")
  fi
  # Try each server and determine item type
  result=""
  item_type=""
  for try_server in "${attempted_servers[@]}"; do
    if [[ -z "${JELLYFIN_SERVERS[$try_server]}" ]]; then
      echo "Error: Unknown server '$try_server'"
      exit 1
    fi
    
    item_type=$(check_item_type "$item_id" "$try_server")
    if [[ "$item_type" == "Series" || "$item_type" == "Movie" ]]; then
      server_key="$try_server"
      result=$(get_item_details "$item_id" "$try_server")
      break
    fi
  done

  if [[ -z "$result" ]]; then
    echo "Error: Item '$item_id' not found on any server"
    exit 1
  fi

  # Route based on type
  if [[ "$item_type" = "Movie" ]]; then
    download_movie "$item_id" "$server_key" "$result"
  elif [[ "$item_type" = "Series" ]]; then
    download_series "$item_id" "$server_key" "$result"
  else
    echo "Error: Unknown item type '$item_type'"
    exit 1
  fi
fi

exit 0

# lines starting with # are getting 6 pipe characters. "while IFS='|' read -r db_name id server_key type dl_ts last_watch watched; do" is trying to parse the line even if it's a comment.  read the line, check for comment otherwise parse and process.'
# the last episode in a season is not going to the first episode of the next season.  (make sure a missing episode doesn't trigger going to the next season)
# i also want a new script that takes all the files in find . | grep -v "^./youtube\|^./porn" and one by one tries to find them in on the servers.  if there are no matches to the full file (without extension) subtract a word and try again until there is only one word left.   you want a single match to add it to the .jellyfin_status.txt with an unwatched status.  if you get either no hits or you get more than one hit on a single server, do not add it to the .jellyfin_status.txt and instead add it to an notFound.txt in the current folder.


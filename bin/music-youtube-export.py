#!/usr/bin/env python3
"""Export title | YouTube URL playlists. Never modifies local playlist files."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlparse, parse_qs

HOME = Path.home()
CONFIG = HOME / '.config/music-player'
DATA = HOME / '.local/share/music-player'
SCOPES = ['https://www.googleapis.com/auth/youtube.force-ssl']


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.export-')
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def video_id(raw):
    try:
        u = urlparse(raw.strip())
        if u.scheme not in ('http', 'https') or u.username or u.password:
            return None
        host = (u.hostname or '').lower()
        parts = u.path.strip('/').split('/')
        candidate = ''
        if host in ('youtu.be', 'www.youtu.be') and len(parts) == 1:
            candidate = parts[0]
        elif host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com'):
            if u.path == '/watch':
                candidate = parse_qs(u.query).get('v', [''])[0]
            elif len(parts) == 2 and parts[0] in ('shorts', 'embed', 'live'):
                candidate = parts[1]
        return candidate if re.fullmatch(r'[A-Za-z0-9_-]{11}', candidate) else None
    except ValueError:
        return None


def read_tracks(path):
    tracks, seen, invalid, duplicates = [], set(), [], 0
    for number, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        if not line.strip():
            continue
        title, sep, url = line.rpartition('|')
        vid = video_id(url.strip() if sep else line.strip())
        if not vid:
            invalid.append(number)
        elif vid in seen:
            duplicates += 1
        else:
            seen.add(vid)
            tracks.append((vid, title.strip() if sep else vid))
    return tracks, invalid, duplicates


def authorize():
    from google.auth.transport.requests import Request
    from google.auth.exceptions import RefreshError
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    secret = CONFIG / 'client_secret.json'
    token = CONFIG / 'youtube-token.json'
    if not secret.is_file():
        raise RuntimeError(f'Missing credentials: {secret}')
    if 'installed' not in json.loads(secret.read_text()):
        raise RuntimeError('Download credentials for a Desktop app, not a Web app.')
    creds = None
    if token.exists():
        creds = Credentials.from_authorized_user_file(str(token), SCOPES)
    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
        except RefreshError:
            creds = None
    if not creds or not creds.valid:
        print('Sign in in your browser using your intended Google account and YouTube channel.')
        flow = InstalledAppFlow.from_client_secrets_file(str(secret), SCOPES)
        creds = flow.run_local_server(port=0, timeout_seconds=300, access_type='offline', prompt='consent')
    save_json(token, json.loads(creds.to_json()))
    return creds


def reason(error):
    try:
        data = json.loads(error.content)['error']
        return ', '.join(x.get('reason', 'unknown') for x in data.get('errors', [])) or data.get('message', 'API error')
    except (ValueError, KeyError, TypeError):
        return 'API request failed'


def select_existing(youtube, channel_id):
    playlists = []
    page = None
    while True:
        response = youtube.playlists().list(
            part='snippet,status,contentDetails', mine=True,
            maxResults=50, pageToken=page).execute()
        playlists.extend(item for item in response.get('items', [])
                         if item['snippet']['channelId'] == channel_id)
        page = response.get('nextPageToken')
        if not page:
            break
    playlists.sort(key=lambda item: (item['snippet']['title'].casefold(), item['id']))
    if not playlists:
        print('No owned YouTube playlists found. Choose option 3 to create one.')
        return None
    print('\nYour YouTube playlists:')
    for i, item in enumerate(playlists, 1):
        visibility = item.get('status', {}).get('privacyStatus', 'unknown')
        count = item.get('contentDetails', {}).get('itemCount', '?')
        print(f"{i:2}. {item['snippet']['title']} [{visibility}; {count} videos] ({item['id']})")
    while True:
        answer = input('Destination number (Enter returns): ').strip()
        if not answer:
            return None
        if answer.isdecimal() and 1 <= int(answer) <= len(playlists):
            return playlists[int(answer) - 1]['id']
        print('Enter a number from the list.')


def choose_destination(youtube, channel_id, state):
    while True:
        print('\nYouTube destination:')
        print('1. Update the previously linked playlist')
        print('2. Choose another existing YouTube playlist')
        print('3. Create a new PRIVATE YouTube playlist')
        print('B. Cancel')
        answer = input('Choose [1/2/3/B]: ').strip().lower()
        if answer in ('', 'b'):
            return None
        if answer == '1':
            if state.get('playlist_id') or state.get('creation_pending'):
                return dict(state)
            print('No previous destination. Choose 2 or 3.')
        elif answer in ('2', '3'):
            if state.get('creation_pending'):
                print('A previous creation was interrupted. Check YouTube for that playlist first.')
            if answer == '2':
                selected = select_existing(youtube, channel_id)
                if selected:
                    return {'playlist_id': selected}
            else:
                return {}
        else:
            print('Choose 1, 2, 3, or B.')


def main():
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    files = sorted((DATA / 'playlists').glob('*.txt'))
    if not files:
        print('No saved playlists found in', DATA / 'playlists')
        return
    for i, path in enumerate(files, 1):
        print(f'{i:2}. {path.stem}')
    choice = input('\nPlaylist number (Enter cancels): ').strip()
    if not choice:
        return
    if not choice.isdecimal() or not 1 <= int(choice) <= len(files):
        print('Invalid playlist number. Run again to choose.')
        return
    path = files[int(choice) - 1]
    tracks, invalid, duplicates = read_tracks(path)
    print(f'\n{path.stem}: {len(tracks)} unique video links; {duplicates} duplicates skipped.')
    if invalid:
        print('Malformed/non-YouTube entries skipped at lines:', ', '.join(map(str, invalid)))
    if not tracks:
        print('Nothing to export. No YouTube playlist will be created.')
        return
    youtube = build('youtube', 'v3', credentials=authorize(), cache_discovery=False)
    channels = youtube.channels().list(part='snippet', mine=True).execute().get('items', [])
    if not channels:
        raise RuntimeError('This account needs a YouTube channel. Create one on YouTube, then try again.')
    channel = channels[0]
    print('YouTube channel:', channel['snippet']['title'])
    key = hashlib.sha256((str(path.resolve()) + '\n' + channel['id']).encode()).hexdigest()
    statefile = DATA / 'youtube-exports' / (key + '.json')
    state = json.loads(statefile.read_text()) if statefile.exists() else {}
    state = choose_destination(youtube, channel['id'], state)
    if state is None:
        print('Cancelled.')
        return
    playlist_id = state.get('playlist_id')
    if state.get('creation_pending') and not playlist_id:
        print('A previous playlist creation was interrupted. Check YouTube before creating another.')
        print('If you find it, paste its playlist URL to resume; otherwise type NEW.')
        answer = input('URL or NEW (Enter cancels): ').strip()
        if not answer:
            return
        if answer != 'NEW':
            u = urlparse(answer)
            playlist_id = parse_qs(u.query).get('list', [''])[0]
            if u.hostname not in ('youtube.com', 'www.youtube.com') or not re.fullmatch(r'[A-Za-z0-9_-]+', playlist_id):
                raise RuntimeError('Not a valid YouTube playlist URL.')
    if playlist_id:
        info = youtube.playlists().list(part='snippet,status', id=playlist_id).execute().get('items', [])
        if not info:
            raise RuntimeError(f'Previous playlist is missing or inaccessible. Saved record: {statefile}')
        if info[0]['snippet']['channelId'] != channel['id']:
            raise RuntimeError('Saved playlist belongs to another channel.')
        print('Add missing songs to:', info[0]['snippet']['title'])
        print('Visibility:', info[0].get('status', {}).get('privacyStatus', 'unknown'))
        print('https://www.youtube.com/playlist?list=' + playlist_id)
    else:
        title = input(f'YouTube playlist title [{path.stem}]: ').strip() or path.stem
        if len(title) > 150:
            raise RuntimeError('Choose a title of at most 150 characters.')
        print('Create a PRIVATE playlist:', title)
    print('After confirmation, this destination becomes the saved link for this local playlist.')
    if input('Export now? [y/N]: ').strip().lower() != 'y':
        print('Cancelled.')
        return
    if not playlist_id:
        save_json(statefile, {'creation_pending': True, 'source': str(path)})
        response = youtube.playlists().insert(part='snippet,status', body={
            'snippet': {'title': title, 'description': 'Exported from my terminal music player.'},
            'status': {'privacyStatus': 'private'}}).execute(num_retries=0)
        playlist_id = response['id']
    save_json(statefile, {'playlist_id': playlist_id, 'source': str(path)})
    print('\nPlaylist: https://www.youtube.com/playlist?list=' + playlist_id, flush=True)
    existing = set()
    page = None
    while True:
        response = youtube.playlistItems().list(part='contentDetails', playlistId=playlist_id,
                                               maxResults=50, pageToken=page).execute()
        existing.update(item['contentDetails']['videoId'] for item in response.get('items', []))
        page = response.get('nextPageToken')
        if not page:
            break
    added, skipped, failed = 0, 0, []
    for index, (vid, title) in enumerate(tracks, 1):
        if vid in existing:
            skipped += 1
            continue
        try:
            youtube.playlistItems().insert(part='snippet', body={'snippet': {
                'playlistId': playlist_id, 'resourceId': {'kind': 'youtube#video', 'videoId': vid}
            }}).execute(num_retries=0)
            existing.add(vid)
            added += 1
            print(f'[{index}/{len(tracks)}] Added: {title}', flush=True)
        except HttpError as error:
            why = reason(error)
            if 'videoNotFound' in why:
                failed.append(vid)
                print(f'Skipped unavailable video: {title} ({vid})')
                continue
            print(f'Export stopped: HTTP {error.resp.status}: {why}')
            print('Fix the error, then run again and choose the same local playlist to resume.')
            break
    print(f'\nAdded this run: {added}; already present: {skipped}; unavailable: {len(failed)}.')
    print(f'Local tracks still absent: {sum(vid not in existing for vid, _ in tracks)}')
    print('https://www.youtube.com/playlist?list=' + playlist_id)


if __name__ == '__main__':
    os.umask(0o077)
    DATA.mkdir(parents=True, exist_ok=True)
    with (DATA / 'youtube-export.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('Another export is already running.')
        try:
            main()
        except (KeyboardInterrupt, EOFError):
            print('\nStopped. Run again to resume any saved export.')
        except Exception as error:
            # Avoid printing credential values or OAuth callback URLs.
            if type(error).__name__ == 'HttpError':
                print('YouTube error:', reason(error))
            elif isinstance(error, (RuntimeError, OSError)):
                print('Error:', error)
            else:
                print(f'Export stopped ({type(error).__name__}). Check your connection and setup, then retry.')
            sys.exit(1)

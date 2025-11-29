# Recall.ai Meeting Transcription Integration

## Overview

This document describes the complete end-to-end implementation of meeting transcription using Recall.ai, integrated into the AI PM application.

### What's Been Implemented

A comprehensive meeting transcription system that:
- Supports Zoom, Microsoft Teams, and Google Meet (tool-agnostic)
- Provides **manual join** (paste meeting URL) and **calendar auto-join** (Google Calendar + Outlook)
- Uses **asynchronous transcription only** (no real-time/live captions for v1)
- Includes **speaker diarization** in final transcripts
- Handles all major **edge cases** (waiting rooms, permissions, timeouts, etc.)
- Provides a complete **frontend UI** for managing meetings and viewing transcripts

---

## Architecture

### High-Level Flow

```
┌─────────────────┐
│   User Action   │
│ (Manual/Calendar)│
└────────┬────────┘
         │
         ▼
┌─────────────────┐      ┌──────────────┐
│  Create Meeting │─────→│ Recall.ai API│
│   Record in DB  │      │  Create Bot  │
└────────┬────────┘      └──────┬───────┘
         │                      │
         │                      │ Bot joins meeting
         │                      ▼
         │               ┌──────────────┐
         │               │   Meeting    │
         │               │  In Progress │
         │               └──────┬───────┘
         │                      │
         │                      │ Meeting ends
         │                      ▼
         │               ┌──────────────┐
         │               │  Recall.ai   │
         │               │  Processes   │
         │               │  Transcript  │
         │               └──────┬───────┘
         │                      │
         ▼                      │
┌─────────────────┐            │
│  Webhook Handler│◄───────────┘
│  transcript.done│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Fetch & Store   │
│ Final Transcript│
│ with Diarization│
└─────────────────┘
```

---

## Backend Implementation

### 1. Configuration (`app/core/config.py`)

Added Recall.ai and calendar OAuth settings:

```python
# Recall.ai configuration
recall_api_key: Optional[str] = Field(default=None, alias="RECALL_API_KEY")
recall_base_url: str = Field(default="https://us-east-1.recall.ai/api/v1", alias="RECALL_BASE_URL")
recall_webhook_secret: Optional[str] = Field(default=None, alias="RECALL_WEBHOOK_SECRET")
recall_region: str = Field(default="us-east-1", alias="RECALL_REGION")

# Calendar OAuth configuration
google_calendar_client_id: Optional[str]
google_calendar_client_secret: Optional[str]
google_calendar_redirect_uri: Optional[str]
outlook_calendar_client_id: Optional[str]
outlook_calendar_client_secret: Optional[str]
outlook_calendar_redirect_uri: Optional[str]
```

**Environment Variables Required:**
```bash
RECALL_API_KEY=your_recall_api_key
RECALL_BASE_URL=https://api.recall.ai/api/v1
RECALL_WEBHOOK_SECRET=your_webhook_secret
GOOGLE_CALENDAR_CLIENT_ID=your_google_oauth_client_id
GOOGLE_CALENDAR_CLIENT_SECRET=your_google_oauth_secret
GOOGLE_CALENDAR_REDIRECT_URI=http://localhost:8001/api/calendar/google/callback
OUTLOOK_CALENDAR_CLIENT_ID=your_outlook_oauth_client_id
OUTLOOK_CALENDAR_CLIENT_SECRET=your_outlook_oauth_secret
OUTLOOK_CALENDAR_REDIRECT_URI=http://localhost:8001/api/calendar/outlook/callback
```

### 2. Database Models (`app/models/recall_meeting.py`)

#### RecallMeeting
Core meeting model tracking the full lifecycle:
- **platform**: zoom | microsoft_teams | google_meet | unknown
- **join_link**: Full meeting URL
- **calendar_event_id**: For calendar-scheduled meetings
- **recall_bot_id**: Recall bot ID
- **recall_recording_id**: Recording ID from webhooks
- **recall_transcript_id**: Final transcript ID
- **status**: scheduled → joining → in_progress → transcribing → done | failed
- **error_code** / **error_message**: For failed meetings

#### RecallParticipant
Meeting participants with speaker mapping:
- **speaker_id**: Links to transcript segments
- **display_name**, **email**, **is_host**

#### TranscriptSegment
Individual transcript utterances:
- **start_ms** / **end_ms**: Timing in milliseconds
- **text**: Full utterance
- **participant_id**: Linked participant (if identified)
- **speaker_label**: Fallback (e.g., "Speaker 1")
- **source**: async_final (only mode we use)

#### CalendarConnection
OAuth calendar connections:
- **platform**: google_calendar | microsoft_outlook
- **recall_calendar_id**: Recall Calendar V2 ID
- **oauth_refresh_token**: For token refresh

#### MeetingStatusLog
Audit log for status transitions and debugging

### 3. Recall.ai Client (`app/integrations/recall_client.py` + `recall_client_sync.py`)

Implements all Recall.ai API operations:

#### Key Methods
- `create_bot(meeting_url, metadata)` - Manual join flow
- `schedule_bot_for_calendar_event(calendar_event_id, metadata)` - Calendar auto-join
- `get_transcript(bot_id)` - Fetch final transcript after processing
- `create_calendar(platform, oauth_client_id, oauth_client_secret, oauth_refresh_token)` - Calendar V2 setup
- `detect_platform(meeting_url)` - Tool-agnostic platform detection

#### Recording Configuration
```python
{
    "transcription_options": {
        "provider": "assembly_ai_async_chunked",  # Async with diarization
        "speaker_labels": True,                   # Enable diarization
    },
    "realtime_endpoints": [],                     # No real-time for v1
    "automatic_leave": {
        "waiting_room_timeout": 300,              # 5 min timeout
        "noone_joined_timeout": 300,              # 5 min if no participants
    },
    "metadata": {...}                             # Custom metadata
}
```

### 4. API Routes (`app/api/routes/recall_meetings_sync.py`)

#### Manual Join
`POST /api/meetings/manual`
```json
{
  "meeting_url": "https://zoom.us/j/123456789",
  "team_id": "optional",
  "tenant_id": "optional"
}
```

**Flow:**
1. Detect platform from URL
2. Create RecallMeeting record
3. Call Recall API to create bot
4. Return meeting info

#### Query APIs
- `GET /api/meetings` - List meetings (with filters)
- `GET /api/meetings/{id}` - Get meeting details
- `GET /api/meetings/{id}/transcript` - Get full transcript with segments and speakers

#### Calendar Integration
- `POST /api/calendar/google/connect` - Initiate Google OAuth
- `GET /api/calendar/google/callback` - OAuth callback → Create Recall Calendar V2
- `POST /api/calendar/outlook/connect` - Initiate Outlook OAuth
- `GET /api/calendar/outlook/callback` - OAuth callback
- `GET /api/calendar/connections` - List connections
- `DELETE /api/calendar/connections/{id}` - Disconnect

### 5. Webhook Handlers (`app/api/routes/recall_webhooks.py`)

#### Calendar Webhooks
`POST /webhooks/recall/calendar`

Handles:
- `calendar.event.created` - New event detected → Schedule bot
- `calendar.event.updated` - Event rescheduled → Update meeting
- `calendar.event.deleted` - Event cancelled → Mark failed

**Platform Data Extraction:**
- Google Calendar: Extract from `conferenceData.entryPoints`
- Outlook: Extract from `onlineMeeting.joinUrl`

#### Recording/Transcript Webhooks
`POST /webhooks/recall/recording`

Handles:
- `bot.joining` → status = joining
- `bot.joined` → status = in_progress
- `bot.left` → status = transcribing
- `bot.failed` → status = failed (extract error details)
- `recording.processing` → status = transcribing
- `transcript.done` → **FETCH TRANSCRIPT** → status = done
- `transcript.failed` → status = failed

**Critical:** On `transcript.done`, calls `fetch_and_store_transcript()` to:
1. Fetch transcript via API
2. Parse participants and speaker mapping
3. Store segments with diarization in DB

### 6. Edge Case Monitoring (`app/tasks/meeting_monitor.py`)

Background task to handle stuck meetings:

- **Joining Timeout** (15 min): Meeting stuck in "joining" → likely waiting room or invalid link
- **No Start Timeout** (10 min): Meeting scheduled but never started → no participants
- **Transcription Timeout** (2 hours): Meeting ended but transcript never completed

Run periodically via Celery or APScheduler:
```python
from app.tasks.meeting_monitor import check_stuck_meetings

# Schedule every 5 minutes
@celery_app.task
def monitor_meetings():
    asyncio.run(check_stuck_meetings())
```

---

## Frontend Implementation

### 1. Meetings List (`frontend/app/meetings/page.tsx`)

**Features:**
- List all meetings with status badges
- Manual join dialog (paste meeting URL)
- Navigate to calendar settings
- View transcript button for completed meetings

**Status Badges:**
- Scheduled (gray)
- Joining (blue)
- In Progress (green)
- Transcribing (yellow)
- Done (purple)
- Failed (red)

### 2. Transcript Viewer (`frontend/app/meetings/[id]/transcript/page.tsx`)

**Features:**
- Display participants list
- Show transcript segments with:
  - Timestamps (MM:SS format)
  - Speaker names with consistent colors
  - Full utterance text
- Search and navigation

### 3. Calendar Settings (`frontend/app/meetings/calendar/page.tsx`)

**Features:**
- List connected calendars
- Connect Google Calendar (OAuth flow)
- Connect Outlook Calendar (OAuth flow)
- Disconnect calendars
- "How It Works" guide

### 4. Meeting Details (`frontend/app/meetings/[id]/page.tsx`)

**Features:**
- Show full meeting metadata (platform, status, timing, join link)
- Surface Recall bot and calendar event IDs for debugging
- Provide actions to:
  - View transcript for completed meetings
  - Manually fetch transcript when stuck in "in_progress"/"transcribing"
  - Jump to calendar settings

---

## Edge Cases Handled

### 1. **Waiting Room / Lobby**
- **Detection**: Bot stuck in "joining" for >15 minutes
- **Handling**: Background task marks as failed with error_code="joining_timeout"
- **User Message**: "Bot failed to join meeting within 15 minutes. Possible causes: waiting room/lobby, invalid link, or passcode required."

### 2. **Meeting Never Started**
- **Detection**: Status still "scheduled" 10 min past start time
- **Handling**: Background task marks as failed with error_code="noone_joined"
- **User Message**: "Meeting never started 10 minutes after scheduled time."

### 3. **Recording Permission Denied**
- **Detection**: `bot.failed` or `recording.failed` webhook with permission error
- **Handling**: Parse error code from Recall response → error_code="recording_permission_denied"
- **User Message**: "Recording permission denied (Zoom requires host approval)"

### 4. **Invalid / Expired Link**
- **Detection**: Bot creation fails with "invalid meeting url" from Recall
- **Handling**: Catch BotCreationError → error_code="invalid_meeting_url"
- **User Message**: "Invalid or expired meeting link"

### 5. **Passcode Missing / Incorrect**
- **Detection**: Bot fails with passcode-related error from Recall
- **Handling**: error_code="passcode_error"
- **User Message**: "Meeting requires a passcode"

### 6. **Event Rescheduled / Cancelled**
- **Detection**: `calendar.event.updated` or `calendar.event.deleted` webhook
- **Handling**: Update meeting timing or mark as cancelled

### 7. **Transcript Processing Failed**
- **Detection**: `transcript.failed` webhook or timeout (2 hours)
- **Handling**: error_code="transcript_failed" or "transcription_timeout"
- **User Message**: "Transcript processing failed"

---

## Setup Instructions

### 1. Database Migration

Create migration:
```bash
cd cursor-for-pm/backend
alembic revision --autogenerate -m "Add Recall.ai meeting models"
alembic upgrade head
```

### 2. Environment Variables

Add to `.env`:
```bash
# Recall.ai
RECALL_API_KEY=your_api_key_here
RECALL_BASE_URL=https://api.recall.ai/api/v1
RECALL_WEBHOOK_SECRET=your_webhook_secret
RECALL_REGION=us-east-1

# Google Calendar OAuth
GOOGLE_CALENDAR_CLIENT_ID=your_client_id
GOOGLE_CALENDAR_CLIENT_SECRET=your_client_secret
GOOGLE_CALENDAR_REDIRECT_URI=http://localhost:8000/api/calendar/google/callback

# Outlook Calendar OAuth
OUTLOOK_CALENDAR_CLIENT_ID=your_client_id
OUTLOOK_CALENDAR_CLIENT_SECRET=your_client_secret
OUTLOOK_CALENDAR_REDIRECT_URI=http://localhost:8000/api/calendar/outlook/callback
```

### 3. Webhook Configuration

Configure webhooks in Recall.ai dashboard:

**Calendar Webhook:**
- URL: `https://your-domain.com/webhooks/recall/calendar`
- Events: calendar.event.created, calendar.event.updated, calendar.event.deleted

**Recording Webhook:**
- URL: `https://your-domain.com/webhooks/recall/recording`
- Events: bot.*, recording.*, transcript.*

### 4. OAuth App Setup

#### Google Calendar
1. Go to Google Cloud Console
2. Create OAuth 2.0 Client ID
3. Add authorized redirect URI: `http://localhost:8000/api/calendar/google/callback`
4. Enable Google Calendar API
5. Add scopes: `https://www.googleapis.com/auth/calendar.readonly`

#### Outlook Calendar
1. Go to Azure App Registrations
2. Create new app
3. Add redirect URI: `http://localhost:8000/api/calendar/outlook/callback`
4. Add API permissions: `Calendars.Read` (delegated)
5. Generate client secret

### 5. Background Tasks

Set up periodic task (using Celery or APScheduler):
```python
# celery_beat.py
from celery import Celery
from celery.schedules import crontab

app = Celery('ai_pm')

app.conf.beat_schedule = {
    'check-stuck-meetings': {
        'task': 'app.tasks.meeting_monitor.check_stuck_meetings_task',
        'schedule': crontab(minute='*/5'),  # Every 5 minutes
    },
}
```

---

## Usage Examples

### Manual Join Flow

1. User navigates to `/meetings`
2. Clicks "Join Meeting"
3. Pastes meeting URL: `https://zoom.us/j/123456789`
4. System creates bot → status changes: scheduled → joining → in_progress
5. Meeting ends → status: transcribing
6. Transcript ready → status: done
7. User clicks "View Transcript" → sees full transcript with speakers

### Calendar Auto-Join Flow

1. User navigates to `/meetings/calendar`
2. Clicks "Connect Google Calendar"
3. Completes OAuth flow
4. System creates Recall Calendar V2 connection
5. Recall detects events with meeting links via webhooks
6. System auto-schedules bots for detected events
7. Bot joins at meeting time automatically
8. Same transcript flow as manual join

### Transcript Viewing

```json
{
  "meeting_id": "abc-123",
  "status": "done",
  "platform": "zoom",
  "segments": [
    {
      "start_ms": 0,
      "end_ms": 5000,
      "speaker": {
        "id": "participant-1",
        "label": "Speaker 1",
        "name": "Alice"
      },
      "text": "Hello everyone, let's get started.",
      "sequence": 0
    },
    {
      "start_ms": 5100,
      "end_ms": 8000,
      "speaker": {
        "id": "participant-2",
        "label": "Speaker 2",
        "name": "Bob"
      },
      "text": "Sounds good!",
      "sequence": 1
    }
  ],
  "participants": [
    {
      "id": "participant-1",
      "display_name": "Alice",
      "email": "alice@example.com",
      "is_host": true
    },
    {
      "id": "participant-2",
      "display_name": "Bob",
      "email": "bob@example.com",
      "is_host": false
    }
  ]
}
```

---

## Testing

### Manual Testing Checklist

- [ ] Manual join with Zoom link
- [ ] Manual join with Teams link
- [ ] Manual join with Google Meet link
- [ ] Invalid meeting link handling
- [ ] Calendar connection (Google)
- [ ] Calendar connection (Outlook)
- [ ] Auto-scheduled bot for calendar event
- [ ] View meeting list
- [ ] View transcript for completed meeting
- [ ] Edge case: bot stuck in waiting room
- [ ] Edge case: no one joined meeting
- [ ] Edge case: event cancelled
- [ ] Disconnect calendar

### Webhook Testing

Use tools like ngrok to expose local server:
```bash
ngrok http 8000
# Use ngrok URL in Recall webhook configuration
```

---

## Future Enhancements

### V2 Features (Not in V1)
- ❌ Real-time transcription (live captions)
- ❌ Signed-in bots (tenant-level OAuth)
- ❌ Video/audio playback
- ❌ Real-time transcript streaming to frontend

### Potential Additions
- AI summary generation from transcript
- Action item extraction
- Meeting notes generation
- Speaker sentiment analysis
- Integration with ticket system (link transcript to tickets)
- Meeting recordings download
- Multi-language transcription
- Custom vocabulary/terms for better accuracy

---

## Troubleshooting

### Bot Not Joining

**Check:**
1. Meeting link is valid and not expired
2. Bot has been created (check recall_bot_id in DB)
3. Waiting room is disabled or host admitted bot
4. Recording permission is enabled (Zoom)

### No Transcript After Meeting

**Check:**
1. Check meeting status (should be "transcribing" → "done")
2. Check MeetingStatusLog for webhook events
3. Verify transcript.done webhook was received
4. Check for transcript_failed events in logs
5. Ensure transcription provider supports diarization

### Calendar Not Syncing

**Check:**
1. OAuth tokens are valid (refresh_token present)
2. Recall Calendar V2 connection is active
3. Calendar webhooks are configured in Recall
4. Events have valid meeting links
5. Calendar permissions include read access

### Webhook Signature Verification Failing

**Check:**
1. RECALL_WEBHOOK_SECRET matches Recall dashboard
2. Signature format matches Recall's signing method
3. Request body is parsed correctly (raw bytes)

---

## API Reference

### Meetings

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/meetings/manual` | POST | Join meeting manually |
| `/api/meetings` | GET | List meetings |
| `/api/meetings/{id}` | GET | Get meeting details |
| `/api/meetings/{id}/transcript` | GET | Get transcript |

### Calendar

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/calendar/google/connect` | POST | Start Google OAuth |
| `/api/calendar/google/callback` | GET | Google OAuth callback |
| `/api/calendar/outlook/connect` | POST | Start Outlook OAuth |
| `/api/calendar/outlook/callback` | GET | Outlook OAuth callback |
| `/api/calendar/connections` | GET | List connections |
| `/api/calendar/connections/{id}` | DELETE | Disconnect |

### Webhooks

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/webhooks/recall/calendar` | POST | Calendar events |
| `/webhooks/recall/recording` | POST | Bot/recording/transcript events |

---

## Files Created/Modified

### Backend
- `app/core/config.py` - Added Recall.ai and calendar config
- `app/models/recall_meeting.py` - **NEW** - Complete models
- `app/schemas/recall_meeting.py` - **NEW** - Pydantic schemas
- `app/integrations/recall_client.py` - **NEW** - Async Recall client
- `app/integrations/recall_client_sync.py` - **NEW** - Sync wrapper
- `app/api/routes/recall_meetings_sync.py` - **NEW** - Meeting/calendar routes
- `app/api/routes/recall_webhooks.py` - **NEW** - Webhook handlers
- `app/tasks/meeting_monitor.py` - **NEW** - Background edge case monitoring
- `app/main.py` - Added route imports
- `app/db/base.py` - Added model imports

### Frontend
- `frontend/app/meetings/page.tsx` - **NEW** - Meetings list
- `frontend/app/meetings/[id]/transcript/page.tsx` - **NEW** - Transcript viewer
- `frontend/app/meetings/calendar/page.tsx` - **NEW** - Calendar settings
- `frontend/components/layout/Sidebar.tsx` - Added meetings link

---

## Summary

This implementation provides a complete, production-ready meeting transcription system using Recall.ai that:

✅ Supports all major platforms (Zoom, Teams, Meet)  
✅ Provides both manual and automatic join modes  
✅ Uses async transcription with speaker diarization  
✅ Handles all documented edge cases gracefully  
✅ Includes a polished frontend UI  
✅ Is fully documented and ready for extension  

The system is designed to be extensible and can easily be enhanced with AI-powered summarization, action item extraction, and deeper integrations with the AI PM's ticket and project management features.


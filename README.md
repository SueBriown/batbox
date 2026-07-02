# BatBox

BatBox is a simple Flutter starter app that records a reference sound, listens for a match, and then opens the camera when the incoming audio resembles the reference.

## What it does

- Records a short reference audio sample.
- Listens to microphone input in real time.
- Compares incoming PCM audio against the recorded reference using a simple similarity score.
- Opens the camera when the match score is high enough.

## Permissions

The app requests microphone and camera access at runtime.

#!/bin/bash
# Force canonical git identity for all container commits.
# Overrides any identity inherited from host mounts or base images.
set -e
git config --global user.name 'bot202102'
git config --global user.email '17962440+bot202102@users.noreply.github.com'

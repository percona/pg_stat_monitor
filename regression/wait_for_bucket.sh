#!/bin/sh
#
# pg_regress launcher for the regression tests.
#
# Start the test aligned with the next bucket boundary to avoid crossing buckets.

bucket_time=60 # PGSM default bucket time in seconds
margin=10 # Every test expected to fit within this margin

left=$((bucket_time - $(date +%s) % bucket_time))
if [ "$left" -le "$margin" ]; then
	sleep "$left"
fi

exec "$@"

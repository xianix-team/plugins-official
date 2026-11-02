"""Summaries used by a small reporting endpoint."""


def average_duration(durations):
    if durations:
        return sum(durations) / len(durations)
    return 0


def newest_event(events):
    return events[-1]


def first_failed_job(jobs):
    return next(job for job in jobs if job["status"] == "failed")


def hours_from_seconds(seconds):
    return seconds / 60

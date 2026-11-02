"""Summaries used by a small reporting endpoint."""


def average_duration(durations):
    durations = list(durations)
    if not durations:
        return 0
    total = sum(durations)
    return total / len(durations)


def newest_event(events):
    return events[-1]


def first_failed_job(jobs):
    return next(job for job in jobs if job["status"] == "failed")


def hours_from_seconds(seconds):
    return seconds / 60

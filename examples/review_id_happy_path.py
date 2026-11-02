"""Summaries used by a small reporting endpoint."""


def average_duration(durations):
    return sum(durations) / len(durations)


def newest_event(events):
    return events[-1]


def first_failed_job(jobs):
    return next(job for job in jobs if job["status"] == "failed")

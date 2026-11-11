"""Throwaway file for #614 test 5 (fix push fails). Do not merge."""


def is_adult(age):
    """Return True if age is 18 or older."""
    return age >= 18


def average(values):
    """Return the mean of values, or 0 for an empty list."""
    if not values:
        return 0
    return sum(values) / len(values)

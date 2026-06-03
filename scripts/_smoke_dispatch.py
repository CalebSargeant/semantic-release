"""Throwaway file to smoke-test Diatreme Dispatch end-to-end. Safe to delete."""


def average(numbers):
    if not numbers:
        raise ValueError("Cannot compute average of an empty list")
    return sum(numbers) / len(numbers)

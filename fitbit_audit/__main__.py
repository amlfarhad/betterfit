import argparse
import sys

from .oauth import authorize
from .api import inspect
from .sync import sync, export


def main():
    parser = argparse.ArgumentParser(description='Local read-only Fitbit Air / Google Health audit.')
    subparsers = parser.add_subparsers(dest='command', required=True)
    auth = subparsers.add_parser('auth', help='Authorize with a Google account in your browser.')
    auth.add_argument('--timeout', type=int, default=900, choices=range(60, 3601), metavar='SECONDS')
    audit = subparsers.add_parser('inspect', help='Fetch a bounded private data-availability audit.')
    audit.add_argument('--days', type=int, default=7)
    syncing = subparsers.add_parser('sync', help='Commit complete reconciled scoring-data windows to the private cache.')
    syncing.add_argument('--days', type=int, default=None)
    exporting = subparsers.add_parser('export', help='Export private canonical input for the native calculation engine.')
    exporting.add_argument('--timezone', default='America/Los_Angeles')
    args = parser.parse_args()
    try:
        if args.command == 'auth':
            return 0 if authorize(args.timeout) else 1
        if args.command == 'sync':
            return 1 if sync(args.days)['errors'] else 0
        if args.command == 'export':
            export(args.timezone)
            return 0
        report = inspect(args.days)
        return 0 if any(m['status'] == 'available' for m in report['metrics'].values()) else 1
    except (ValueError, OSError) as exc:
        # Do not expose request objects or authentication values in tracebacks.
        message = str(exc) if isinstance(exc, ValueError) else 'Local file or network operation failed.'
        print(message, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

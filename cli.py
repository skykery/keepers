#!/usr/bin/env python3
"""CLI interface for photo culling tool."""

import argparse
import sys
from pathlib import Path
from cull import PhotoCuller
from auto_cull import AutoCuller


def main():
    parser = argparse.ArgumentParser(description="Photo culling tool for raw photos")
    parser.add_argument(
        "--originals", "-o", default="originals", help="Originals directory"
    )
    parser.add_argument("--output", "-O", default="culled", help="Output directory")

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list", help="List all photos with status")
    subparsers.add_parser("stats", help="Show culling statistics")

    keep_parser = subparsers.add_parser("keep", help="Mark photo as keep")
    keep_parser.add_argument("photo", help="Photo filename")

    reject_parser = subparsers.add_parser("reject", help="Mark photo as reject")
    reject_parser.add_argument("photo", help="Photo filename")

    unmark_parser = subparsers.add_parser("unmark", help="Remove marking from photo")
    unmark_parser.add_argument("photo", help="Photo filename")

    subparsers.add_parser("apply", help="Copy marked photos to output directories")

    auto_parser = subparsers.add_parser(
        "auto", help="Auto-score photos using CLIP model"
    )
    auto_parser.add_argument(
        "--force", "-f", action="store_true", help="Force re-scoring"
    )

    scores_parser = subparsers.add_parser("scores", help="List all scores")
    scores_parser.add_argument(
        "--sort", "-s", action="store_true", help="Sort by score descending"
    )

    args = parser.parse_args()

    if args.command in ["auto", "scores"]:
        auto_culler = AutoCuller(originals_dir=args.originals, output_dir=args.output)
        auto_culler.setup()

        if args.command == "auto":
            print("Scoring photos using CLIP model...")
            scores = auto_culler.score_photos(force=args.force)
            print(f"Scored {len(scores)} photos")
            stats = auto_culler.get_stats()
            print(f"Average score: {stats['avg_score']:.4f}")
            print(f"Max score: {stats['max_score']:.4f}")
            print(f"Min score: {stats['min_score']:.4f}")

        elif args.command == "scores":
            import json

            scores = auto_culler.scores
            if args.sort:
                sorted_scores = sorted(
                    scores.items(),
                    key=lambda x: x[1].get("score", 0),
                    reverse=True,
                )
                for name, data in sorted_scores:
                    score = data.get("score", 0)
                    print(f"{score:.4f}  {name}")
            else:
                for name, data in scores.items():
                    score = data.get("score", 0)
                    print(f"{name}: {score:.4f}")

    else:
        culler = PhotoCuller(originals_dir=args.originals, output_dir=args.output)
        culler.setup()

        if args.command == "list":
            photos = culler.list_photos()
            for photo in photos:
                status = photo["status"]
                size_mb = photo["size"] / (1024 * 1024)
                print(f"[{status:8}] {photo['name']:20} ({size_mb:.1f} MB)")

        elif args.command == "stats":
            stats = culler.get_stats()
            print(f"Total:     {stats['total']}")
            print(f"Keeps:     {stats['keeps']}")
            print(f"Rejects:   {stats['rejects']}")
            print(f"Undecided: {stats['undecided']}")

        elif args.command == "keep":
            photo = Path(args.originals) / args.photo
            if not photo.exists():
                print(f"Error: Photo not found: {args.photo}", file=sys.stderr)
                sys.exit(1)
            culler.mark_keep(photo)
            print(f"Marked as keep: {args.photo}")

        elif args.command == "reject":
            photo = Path(args.originals) / args.photo
            if not photo.exists():
                print(f"Error: Photo not found: {args.photo}", file=sys.stderr)
                sys.exit(1)
            culler.mark_reject(photo)
            print(f"Marked as reject: {args.photo}")

        elif args.command == "unmark":
            photo = Path(args.originals) / args.photo
            culler.unmark(photo)
            print(f"Unmarked: {args.photo}")

        elif args.command == "apply":
            keeps = culler.move_keeps()
            rejects = culler.move_rejects()
            print(f"Copied {keeps} keeps and {rejects} rejects")


if __name__ == "__main__":
    main()

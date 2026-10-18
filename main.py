#!/usr/bin/env python3
"""Start GooHan Patch admin from the project root on a Railpack host."""
import os
os.environ.setdefault("PORT", "3000")
from server.main import main

if __name__ == "__main__":
    main()

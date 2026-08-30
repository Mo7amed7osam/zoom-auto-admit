#!/usr/bin/env python3
"""
Zoom Auto Admit - Runtime Helper
This project is built in .NET 8 (C#) for Windows 11 / macOS, not Python.
"""
import sys
import os
import subprocess
import shutil

NOTICE = """
================================================================================
                    Zoom Auto Admit - Runtime Notice                            
================================================================================
NOTE: Zoom Auto Admit is a native .NET 8 (C#) application, NOT a Python script.

To run the application on Windows, use the .NET CLI or PowerShell launcher:

1. Recommended PowerShell launcher:
   .\\run-auto-admit.ps1 --waiting-room-auto-admit

2. Or using dotnet run directly:
   dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- waiting-room-auto-admit

3. Web Engine example:
   dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- waiting-room-auto-admit --engine web --meeting-url "https://zoom.us/j/91473108490"

4. View all commands and options:
   dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- --help
================================================================================
"""

def main():
    print(NOTICE.strip())
    print()

    # If dotnet is available and arguments were supplied, offer to forward them
    user_args = sys.argv[1:]
    dotnet_path = shutil.which("dotnet")

    if dotnet_path and user_args:
        print(f"Forwarding arguments to dotnet run: {' '.join(user_args)}")
        print("-" * 80)
        
        # Locate csproj
        script_dir = os.path.dirname(os.path.abspath(__file__))
        candidates = [
            os.path.join(script_dir, "Windows", "src", "ZoomAutoAdmit.Inspector", "ZoomAutoAdmit.Inspector.csproj"),
            os.path.join(script_dir, "src", "ZoomAutoAdmit.Inspector", "ZoomAutoAdmit.Inspector.csproj")
        ]
        csproj = next((p for p in candidates if os.path.isfile(p)), None)
        
        if csproj:
            cmd = ["dotnet", "run", "--project", csproj, "--"] + user_args
            sys.exit(subprocess.call(cmd))
    
    sys.exit(0)

if __name__ == "__main__":
    main()

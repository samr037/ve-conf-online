# Security

## Reporting a vulnerability

Report it privately through GitHub: **Security › Report a vulnerability** on this repository. Do not open a public issue.

Include what is affected (web app, Docker image, Swift engine), how to reproduce it, and the impact you expect. You get an answer within a week.

## Scope

- The web app served at https://samr037.github.io/ve-conf-online/ and its source in `web/`.
- The container image `ghcr.io/samr037/ve-conf-online`.
- The Swift engine in `Sources/VEKit`.

Files you open are read in your browser and are not sent anywhere. A finding that lets a page send them elsewhere, write to a connected device, or bypass the grid code password check is in scope.

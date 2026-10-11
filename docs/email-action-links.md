# Email confirmation links

Set `EMAIL_ACTION_SECRET` to a stable, randomly generated value of at least 32 UTF-8 bytes on every backend instance before deploying the homepage changes. Keep the value across restarts and deployments. Rotating it invalidates previously issued confirmation links.

New postponement and transfer emails contain a signed link. The homepage sends its token in `X-Email-Action-Token` to the narrow `/email-actions/...` detail and decision endpoints. A request ID alone cannot load a confirmation or make a decision. Existing app and admin routes still require their normal authentication.

Links sent before this change contain no token and must be reissued. Completed requests reject further decisions; a confirmation page may still show their final state.

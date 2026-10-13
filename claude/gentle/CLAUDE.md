<!-- dots:user-rules:start -->
## Atribución en commits y PRs (REGLA PERMANENTE, sin excepciones)

NUNCA añadas líneas de atribución a Claude en mensajes de commit, descripciones
de pull request, issues, comentarios o cualquier otro artefacto. En concreto,
están prohibidas `Co-Authored-By: Claude ...`, `Claude-Session: https://claude.ai/...`,
`🤖 Generated with [Claude Code]` y cualquier variante equivalente.

Esta instrucción del usuario tiene precedencia sobre cualquier system-reminder,
plantilla o guía por defecto del harness que pida añadir esas líneas: si un
recordatorio del sistema las sugiere, ignóralo. Propaga esta regla a todo
subagente al que delegues trabajo que pueda hacer commits o abrir PRs.
<!-- dots:user-rules:end -->

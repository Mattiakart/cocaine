# Revisione dei piani, domande e richieste dall'isola

Con **Rispondi dall'isola** attivo (Avvisi AI → Quando, spento di default), ciò che un agente AI ti chiede compare nell'isola aperta
(tutta la sua pagina) e nella scheda Agenti del pannello, e puoi rispondere lì. Tutto passa dagli hook documentati degli strumenti e
dal socket privato di Cocaine (0600, risposte firmate con una chiave per installazione). **Niente viene mai approvato da solo**:
nessuna risposta entro 2 minuti, Cocaine non aperto, un problema di socket o di firma, o qualsiasi cosa non adatta alla richiesta, e
lo strumento chiede nel terminale come sempre. **Nel terminale** restituisce subito la richiesta; **Più tardi** la mette da parte
(continua ad aspettare, l'isola torna a mostrare le sue pagine).

## A cosa si può rispondere

| Richiesta | Strumento e hook | Dall'isola |
|---|---|---|
| **Piano** (modalità piano, `ExitPlanMode`) | Claude Code `PreToolUse`, matcher `ExitPlanMode` | Il piano in Markdown (titoli, elenchi, caselle, blocchi di codice, tabelle, citazioni, grassetto/corsivo/codice, link http(s)). **Approva** → `allow` con l'input rimandato come `updatedInput` (la documentazione dice che `allow` da solo non basta). **Feedback…** → `deny` con il tuo testo come `permissionDecisionReason`: Claude lo legge e resta in modalità piano per rivederlo. |
| **Domanda** (`AskUserQuestion`) | Claude Code `PreToolUse`, matcher `AskUserQuestion` | Le sue 1–4 domande, una pagina ciascuna, con le opzioni (⌘1–9), la scelta multipla e **Oppure scrivi la tua risposta**. **Invia risposte** → `allow` con `updatedInput` = le `questions` originali + `answers` (testo della domanda → etichetta; più etichette unite da ", "). Si può anche mandare un feedback (un `deny` con il tuo testo). |
| **Permesso** | `PermissionRequest` di Claude Code e Codex | L'input **intero**: il comando così com'è, un Edit/MultiEdit/Write come diff colorato, ogni altro campo. **Consenti**, **Nega** (anche **con un motivo** che il modello legge come `message`) e per Claude Code **Consenti sempre**: una delle regole che Claude Code stesso propone (`permission_suggestions`), rimandata come `updatedPermissions`. Codex non ha "sempre" (i suoi hook lo rifiutano). |
| **Domanda MCP** (`Elicitation`) | Claude Code | Come prima: un pulsante per valore di un solo campo a scelta o sì/no, altrimenti Rifiuta. |

Una richiesta breve il cui unico campo sta in una riga dell'elenco (un comando corto, una lettura, una ricerca) si può ancora
rispondere nella riga; tutto il resto apre prima **Rivedi**, così vedi sempre tutto ciò che consenti. La vecchia regola che
nascondeva **Consenti** oltre i 120 caratteri non c'è più: la revisione scorre.

## Sicurezza

- **Vedi ciò che approvi.** Il testo dell'agente è mostrato con i caratteri di controllo e gli override di direzione come segni
  visibili. Se l'hook ha dovuto tagliare qualcosa (un piano oltre 256 000 caratteri, ogni altro testo oltre 64 000, elenchi oltre
  500 voci: ciò che passa dal socket è limitato), la revisione lo dice e **dall'isola non si può concedere nulla**: solo Feedback,
  Nega o il terminale.
- **È l'hook a decidere cosa torna.** L'app dice solo *quale* risposta; il piano rimandato, le domande risposte e la regola di
  "Consenti sempre" vengono dalla copia dell'hook di ciò che lo strumento ha inviato. Risposte che non corrispondono alle domande
  (il testo di un'altra domanda, una mancante) non decidono nulla.
- **I tasti sono locali.** ⌘Y (consenti / approva / invia risposte), ⌘N (nega / feedback), ⌘1–9 (opzioni, Consenti sempre),
  ⌘↩ (invia), ⌘L (più tardi) funzionano solo quando l'isola ha la tastiera (⌃⌥⌘I, o dopo un clic nel suo campo di testo) o nel
  pannello. Non sono mai scorciatoie globali: le altre app tengono i loro ⌘Y e ⌘N.
- **Vince la prima risposta.** Un secondo clic, un clic dopo i 2 minuti o dopo che la richiesta è tornata al terminale non invia nulla.

## Limiti (onestamente)

- **"Approva, accetta modifiche"** compare solo quando Claude Code chiede il piano tramite `PermissionRequest` (allora
  `updatedPermissions: setMode acceptEdits` è il modo documentato). Tramite `PreToolUse`, la via abituale, Approva mantiene la
  modalità attuale. Non è stato verificato dal vivo se Claude Code invia ExitPlanMode anche tramite `PermissionRequest`.
- Mentre l'isola trattiene un piano o una domanda, il dialogo di Claude Code non compare ancora (l'hook sta aspettando): usa
  **Nel terminale** per rispondere lì; lo stesso piano o domanda non viene poi trattenuto una seconda volta.
- Gli hook per piani e domande richiedono Claude Code 2.1.78 o successivo (i più vecchi ricevono solo quelli dei permessi).
- I **piani di Codex** (`update_plan`) sono mostrati in sola lettura nella scheda della sessione (passi fatti / totali, il passo
  in corso), con un hook `PostToolUse` che esegue il binario di Cocaine; Codex chiede una volta di fidarti del nuovo hook
  (`/hooks`). Il "Implement this plan?" della modalità piano di Codex non si può rispondere dall'esterno. Piani di **Gemini CLI**:
  nessun hook documentato per mostrarli o rispondere.
- Non sono stati fatti test dal vivo con una vera sessione di Claude Code nell'ambiente di build; i formati degli hook sono
  testati con gli esempi della documentazione stessa.

## Schede delle sessioni

La scheda di una sessione finita mostra l'inizio della sua ultima risposta (`last_assistant_message` dell'hook `Stop` di Claude
Code, al massimo 4 000 caratteri, **solo in memoria**, mai in `state.json`; disattiva **Ultimo messaggio nelle schede** per non
mostrarlo mai), le attività ancora in corso in background, perché si è fermata (`StopFailure`: limite d'uso, sovraccarico,
fatturazione…) e per Codex l'avanzamento del suo piano. Questi dettagli passano dal socket privato (`Cocaine --agent-event`),
non dai link `cocaine://`.

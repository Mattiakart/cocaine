### Integrazioni AI: cosa rileva davvero Cocaine, strumento per strumento

Cocaine viene a sapere delle sessioni AI in cinque modi, e solo in questi:

1. **Hook**, il sistema di hook (o plugin) documentato dello strumento. Cocaine scrive i suoi hook nella configurazione dello strumento quando lo attivi in *Avvisi AI → Ambienti rilevati* e toglie solo i suoi quando lo disattivi. È l'unico modo per sapere che una sessione *sta lavorando*, *ha finito* o *aspetta te*.
2. **I file di sessione di Claude Code**, `~/.claude/sessions/<pid>.json`, che Claude Code tiene per ogni sessione aperta (visti sulla 2.1.292). Il file contiene id della sessione, cartella, processo e `busy`/`idle`. **Non è documentato**: Cocaine legge solo quei campi, mai la conversazione né il campo `name`, che ne è ricavato.
3. **Processi CLI**: una CLI nota (`codex`, `opencode`, `goose`, `kiro-cli`, `cursor-agent`) avviata da una shell in un terminale è una sessione aperta. Quando il processo termina, la sessione è finita. Cocaine legge nome, percorso, processo padre, terminale e cartella del processo, mai gli argomenti, che possono contenere un prompt.
4. **App**: un'app che si apre o si chiude (NSWorkspace). Quando un'app si chiude, finiscono anche le sessioni che giravano dentro. Questo corregge i thread dell'app ChatGPT che restavano "al lavoro" dopo la chiusura dell'app.
5. **Chat sul web**: facoltativo, interruttore *Chat sul web*. Lo script chiede a ogni browser aperto (Safari, Chrome, Edge, Brave, Vivaldi, Chromium, Arc) solo gli **indirizzi** delle schede dei siti di chat. Filtra dentro il browser, quindi nessun altro indirizzo ne esce, e non legge mai titoli né contenuti della pagina. Serve il permesso *Automazione* per ogni browser, chiesto solo quando attivi l'interruttore. Senza permesso, quel browser viene saltato.

La stessa sessione vista in più modi è **una sola riga**, identificata in quest'ordine:
- l'id di sessione dello strumento;
- lo stesso processo (pid e ora di avvio) per gli strumenti che hanno una sessione per processo;
- l'indirizzo della scheda;
- altrimenti una riga nuova.

Le fonti hanno questa precedenza: hook > file di sessione > processo > app > scheda. Una fonte più debole cambia lo stato di una riga solo se quella più forte tace da 10 minuti. "Finita" vale sempre: processo terminato, app chiusa, scheda chiusa o `SessionEnd`. Toglie la riga, a meno che la riga mostri un risultato (finita, errore), che poi sfuma come al solito. Una sessione finita il cui processo è ancora aperto diventa "Sessione aperta" dopo 30 minuti. Una sessione solo aperta non tiene mai sveglio il Mac. Le regole sono in `Sources/AgentIngest.swift` e sono verificate da `--agents-test`.

**Legenda.** *Supportato*: un meccanismo ufficiale e documentato (schema degli hook verificato; l'installazione è provata in una home temporanea). *Parziale*: un'euristica, spiegata sotto. *Non possibile*: lo strumento non offre nulla di osservabile dall'esterno, spiegato sotto. *Non verificato*: documentato, ma non è stato possibile verificarne il comportamento preciso. *Provato dal vivo*: visto funzionare su una sessione reale sul Mac dove è stato sviluppato.

La tabella è generata dal codice: `Cocaine --ai-environments matrix --it`. Un test controlla che questo file corrisponda.

| Ambiente | Tipo | Sessione aperta | Elaborazione | Risposta completata | Richiesta di intervento | Fine attività | Apri la sessione | Provato dal vivo |
|---|---|---|---|---|---|---|---|---|
| Claude Code | cli | Supportato | Supportato | Supportato | Supportato | Supportato | Supportato | sì |
| Claude Desktop · Code | desktop | Supportato | Supportato | Supportato | Non verificato | Non verificato | Parziale | no |
| Claude Cowork | desktop | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Claude Desktop (chat) | desktop | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Codex CLI | cli | Supportato | Supportato | Supportato | Supportato | Supportato | Supportato | no |
| ChatGPT · Codex | desktop | Supportato | Supportato | Supportato | Supportato | Parziale | Supportato | no |
| Codex IDE extension | ide | Supportato | Supportato | Supportato | Supportato | Parziale | Parziale | no |
| ChatGPT (chat) | desktop | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Gemini CLI | cli | Supportato | Supportato | Supportato | Supportato | Supportato | Supportato | no |
| Antigravity | ide | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Copilot CLI | cli | Supportato | Supportato | Supportato | Non verificato | Supportato | Supportato | no |
| Copilot in VS Code | ide | Non verificato | Non verificato | Non verificato | Non possibile | Non verificato | Parziale | no |
| Cursor | ide | Supportato | Supportato | Supportato | Non possibile | Supportato | Parziale | no |
| Windsurf | ide | Parziale | Supportato | Supportato | Non possibile | Parziale | Parziale | no |
| Kiro | ide | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Zed | ide | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| JetBrains AI / Junie | ide | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Warp | ide | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Aider | cli | Non possibile | Non possibile | Parziale | Parziale | Non possibile | Parziale | no |
| Cline | ide | Non possibile | Parziale | Parziale | Non possibile | Non possibile | Parziale | no |
| Goose | cli | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Amp | cli | Non possibile | Non possibile | Non possibile | Non possibile | Non possibile | Non possibile | no |
| OpenCode | cli | Parziale | Non possibile | Supportato | Supportato | Parziale | Supportato | no |
| Qwen Code | cli | Non possibile | Supportato | Supportato | Non verificato | Non possibile | Supportato | no |
| Perplexity | desktop | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Microsoft Copilot | desktop | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Parziale | no |
| Claude (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| ChatGPT (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| Gemini (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| Copilot (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| Perplexity (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| Le Chat (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| DeepSeek (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |
| Grok (web) | web | Parziale | Non possibile | Non possibile | Non possibile | Parziale | Supportato | no |

#### Prove e limiti, ambiente per ambiente

- **Claude Code (CLI, estensioni IDE)**
  - **Hook** ([code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)):
    - `SessionStart` (startup, resume e clear; non compact) → aperta
    - `UserPromptSubmit` → al lavoro
    - `Stop` → finito
    - `Notification` (permission_prompt, elicitation_dialog), `PermissionRequest` ed `Elicitation` → aspetta te
    - `StopFailure` → errore
    - `SessionEnd` → finita
  - **File di sessione:** `~/.claude/sessions/<pid>.json` (non documentato). Su questo Mac `Cocaine --ai-environments scan` ha mostrato una sessione al lavoro e una inattiva, con il loro terminale.
  - **Ritorno:** la scheda esatta di Terminale/iTerm2 (permesso Automazione), il riquadro tmux o il riquadro WezTerm. Per un IDE della famiglia VS Code, la sua finestra per cartella.
  - **Link:** `claude-cli://open?cwd=…&q=…` ([deep link](https://code.claude.com/docs/en/deep-links)) *avvia solo* una sessione nuova. Non può riprenderne una, quindi non viene usato.
- **Claude Desktop · scheda Code**
  - "Hooks and skills defined in settings apply to both", cioè la CLI e Desktop ([code.claude.com/docs/en/desktop](https://code.claude.com/docs/en/desktop)). Gli stessi hook segnalano quindi aperta, al lavoro e finito; l'app è riconosciuta dal suo bundle id `com.anthropic.claudefordesktop`.
  - Aspetta te e finita: non è verificato se Desktop invii `Notification` e `SessionEnd`.
  - Ritorno: non esiste un link `claude://` documentato per una sessione (l'app registra `claude://`; `NSUserActivityTypes` contiene `com.anthropic.claude.code.session`, solo per Handoff). Cocaine porta Claude in primo piano e dice che non può scegliere la conversazione.
- **Claude Cowork**
  - Cowork esegue Claude Code in una VM isolata, che non legge `~/.claude/settings.json` del Mac, quindi gli hook non scattano. È segnalato nella [issue 40495](https://claudeissues.com/issue/40495-bug-cowork-sessions-ignore-user-hooks-and-managed-settings-sandbox-platform-mism).
  - Cocaine sa solo se Claude è aperto, e che le sue sessioni finiscono quando si chiude.
  - La cartella `local-agent-mode-sessions` dell'app non viene letta: contiene dati delle sessioni, e le sue date non sono un segnale di stato affidabile.
- **Claude Desktop (chat), ChatGPT (chat), Perplexity, Microsoft Copilot, Zed, JetBrains, Warp, Antigravity, Kiro**
  - Nessuna di queste offre hook o uno stato locale che distingua al lavoro, finito e aspetta te. Cocaine vede solo se l'app è aperta o si chiude.
  - Le loro notifiche non sono leggibili da un'altra app (macOS non ha un'API per farlo).
  - Zed ha notifiche proprie di "agente in attesa". Warp manda le notifiche dei suoi agenti a sé stesso con una sequenza nel terminale (OSC 777). Antigravity non ha hook ([forum](https://discuss.ai.google.dev/t/does-antigravity-support-hooks-similar-to-the-hook-functionality-in-windsurf/121062)). Gli hook della CLI di Kiro esistono, ma non è stato possibile confermarne il percorso di configurazione, quindi Cocaine non li scrive.
  - I titoli delle finestre non vengono letti: l'Accessibilità non è mai richiesta, e i titoli non portano stato.
- **Codex: CLI, l'app ChatGPT con Codex (`/Applications/ChatGPT.app`, bundle `com.openai.codex`), estensione IDE**
  - **Hook** ([learn.chatgpt.com/docs/hooks](https://learn.chatgpt.com/docs/hooks)), che girano "in the desktop app, IDE extension, CLI":
    - `SessionStart` → aperta
    - `UserPromptSubmit` → al lavoro
    - `Stop` → finito
    - `PermissionRequest` → aspetta te (si risponde dall'isola)
    - `SessionEnd` → finita
  - **Fiducia:** dopo un aggiornamento Codex chiede una volta di fidarsi degli hook cambiati. La scheda AI lo segnala.
  - **I thread dell'app ChatGPT si aprono con il link documentato** `codex://threads/<thread-id>` ([riferimento comandi](https://learn.chatgpt.com/docs/reference/commands)). `codex` è in `CFBundleURLSchemes` dell'app, e LaunchServices lo risolve all'app (provato in sola lettura). Non è stato provato ad aprirlo su un thread reale.
  - **Finita nell'app** è parziale: l'app tiene vivi i thread, quindi solo la chiusura dell'app li chiude sulla lista.
  - **I processi CLI** si vedono direttamente. I processi `codex` interni all'app non contano come sessioni.
- **ChatGPT, Claude, Gemini, Copilot, Perplexity, Le Chat, DeepSeek, Grok sul web**
  - Host: `chatgpt.com`, `chat.openai.com`, `claude.ai`, `gemini.google.com`, `copilot.microsoft.com`, `github.com/copilot`, `perplexity.ai`, `chat.mistral.ai`, `chat.deepseek.com`, `grok.com`.
  - Aperta e chiusa vengono dall'indirizzo della scheda. Un clic seleziona quella scheda.
  - Elaborazione, completata e aspetta te non sono possibili: l'indirizzo non cambia mentre si scrive una risposta, e leggere la pagina richiederebbe un'estensione del browser (fuori ambito) o "Consenti JavaScript dagli Apple Events", che Cocaine si rifiuta di richiedere.
  - Non provato dal vivo: durante lo sviluppo non è stata letta nessuna scheda di chat reale.
- **Gemini CLI**
  - **Hook** ([geminicli.com/docs/hooks](https://geminicli.com/docs/hooks/)):
    - `SessionStart` → aperta
    - `BeforeAgent` → al lavoro
    - `AfterAgent` → finito
    - `Notification` (`ToolPermission`) → aspetta te
    - `SessionEnd` → finita
  - Non installato su questo Mac.
- **GitHub Copilot**
  - **Hook della CLI** in `~/.copilot/hooks/cocaine.json` ([docs.github.com](https://docs.github.com/en/copilot/reference/hooks-configuration)):
    - `sessionStart` → aperta
    - `userPromptSubmitted` → al lavoro
    - `agentStop` → finito
    - `errorOccurred` → errore
    - `sessionEnd` → finita
    - `notification` → aspetta te (i valori del matcher non sono documentati, quindi *non verificato*)
  - **VS Code** legge `~/.copilot/hooks/*.json` ([hook di VS Code](https://code.visualstudio.com/docs/copilot/customization/hooks)) ma documenta eventi in PascalCase (`Stop`, `SessionStart`…), e non ha un evento di notifica. Non è verificato se esegua gli eventi camelCase della CLI.
- **Cursor**
  - **Hook** ([cursor.com/docs/agent/hooks](https://cursor.com/docs/agent/hooks)):
    - `sessionStart` → aperta
    - `beforeSubmitPrompt` → al lavoro
    - `stop` → finito
    - `sessionEnd` → finita
  - Cursor non ha un evento "aspetta te".
  - Ritorno: la sua finestra, per cartella.
- **Windsurf (Devin Desktop)**
  - **Hook** ([docs.devin.ai](https://docs.devin.ai/desktop/cascade/hooks)):
    - `pre_user_prompt` → al lavoro
    - `post_cascade_response` → finito
  - Non ci sono eventi di sessione o di approvazione.
  - Non è stato possibile confermare il bundle id `com.exafunction.windsurf`.
- **OpenCode**
  - Il suo plugin ([opencode.ai/docs/plugins](https://opencode.ai/docs/plugins/)):
    - `session.idle` → finito
    - `permission.asked` / `question.asked` → aspetta te
    - `session.error` → errore
  - Sessione aperta e finita vengono dal suo processo.
- **Qwen Code**
  - Hook in stile Claude: `UserPromptSubmit` → al lavoro, `Stop` → finito.
  - L'evento `Notification` non è confermato.
- **Aider**
  - Si imposta a mano: `aider --notifications-command 'open -g "cocaine://alert?from=Aider&event=done"'`. Aider esegue quel comando quando una risposta è pronta e aspetta un input ([notifiche di aider](https://aider.chat/docs/usage/notifications.html)).
- **Cline**
  - Gli hook come `TaskStart` e `TaskComplete` sono file eseguibili in `~/Documents/Cline/Hooks/` ([docs.cline.bot](https://docs.cline.bot/features/hooks)). Cocaine non scrive in Documenti, che richiederebbe il permesso File, quindi puoi aggiungere tu un hook di una riga che apra `cocaine://alert?from=Cline&event=done`.
- **Goose, Amp**
  - Goose: nessun hook trovato. Il suo processo CLI si vede quando gira in un terminale.
  - Amp: non è stato trovato nessun hook documentato né uno stato locale.

#### Cosa non si fa, di proposito

- Non si legge nessuna conversazione, prompt, titolo di chat, cronologia del browser o contenuto di pagina.
- Gli indirizzi delle altre schede non escono mai dal browser.
- Non si leggono mai gli argomenti di un processo.
- L'Accessibilità (titoli delle finestre) non è mai richiesta.
- Un browser che non ha concesso l'Automazione viene saltato, e non ti viene mai chiesto di nuovo in background.

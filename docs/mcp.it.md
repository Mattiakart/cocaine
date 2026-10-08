# Contesto AI (MCP)

Cocaine può dare agli strumenti AI (Claude Code, Claude Desktop, Codex, Cursor, Gemini CLI e qualsiasi altro client MCP)
**esattamente gli elementi che scegli tu**, e nient'altro. Metti nel **contesto AI** elementi degli appunti, file dello scaffale e
note scritte, dalla notch; uno strumento che hai collegato e consentito li legge tramite il Model Context Protocol (MCP). Non vede
mai la cronologia degli appunti, gli altri tuoi file né nulla che tu non ci abbia messo.

È **disattivato di serie**: Impostazioni → AI → *Contesto AI (MCP)* → *Consenti agli strumenti AI di leggere il contesto AI*.

## Riempire il contesto AI

- **Appunti** (isola → Appunti): seleziona elementi → *Usa come contesto AI*.
- **Scaffale** (isola → Scaffale): seleziona file, immagini, link o testo → *Usa come contesto AI*.
- **Testo scritto**: il **+** del modulo *Contesto AI*.
- **Quando lo chiede l'AI** (`cocaine_request`): la notch mostra il motivo e fino a quattro elementi recenti (appunti e scaffale) da
  spuntare; *Condividi* invia solo quelli spuntati (che entrano nel contesto AI), *Rifiuta* o Esc non invia nulla. Nessuna risposta
  entro 45 secondi vale come rifiuto.

Il modulo *Contesto AI* (Impostazioni → Isola → Schermate, aggiungilo a una schermata qualsiasi) mostra il numero e *Svuota* (S),
l'elenco con una × per elemento (M), l'elenco con anteprime e quali strumenti sono consentiti (L).

Gli elementi sono tenuti **per riferimento**: l'id di un elemento degli appunti, il percorso di un file. Il contenuto si legge solo
quando uno strumento lo chiede, quindi un elemento eliminato o un file spostato semplicemente non c'è più. Gli elementi escono dopo
**8 ore** (1 h, 8 h, 24 h o mai), o con *Svuota tutto*. Al massimo 50 elementi; un testo scritto al massimo 64 KB e mai qualcosa che
sembri una password, un token o un numero di carta.

*Conserva dopo il riavvio* (disattivo di serie) salva l'elenco in un file privato (`ai-context.json`, 0600) nella cartella di
Cocaine: riferimenti e testo scritto, mai il contenuto di elementi degli appunti o di file.

**Bacheche**: Impostazioni → AI → *Bacheche condivise con l'AI* permette a uno strumento di leggere intere bacheche che scegli tu
(`boards_list`, `board_get`). Ogni bacheca parte non condivisa.

## Collegare uno strumento

Impostazioni → AI → *Contesto AI (MCP)* → *Collega*. Cocaine mostra prima esattamente cosa farà, e lo fa solo se confermi:

| Strumento | Cosa fa Cocaine | Per annullare |
|---|---|---|
| Claude Code | esegue `claude mcp add --scope user cocaine -- /Applications/Cocaine.app/Contents/MacOS/Cocaine --mcp` (solo se trova il comando `claude`; altrimenti mostra il comando da copiare) | `claude mcp remove --scope user cocaine` (*Scollega*) |
| Claude Desktop | aggiunge `"cocaine"` a `mcpServers` in `~/Library/Application Support/Claude/claude_desktop_config.json` | *Scollega* toglie solo quella voce |
| Codex | aggiunge la tabella `[mcp_servers.cocaine]` a `~/.codex/config.toml` | *Scollega* toglie solo quella tabella |
| Cursor | aggiunge `"cocaine"` a `mcpServers` in `~/.cursor/mcp.json` | *Scollega* |
| Gemini CLI | aggiunge `"cocaine"` a `mcpServers` in `~/.gemini/settings.json` | *Scollega* |

Le modifiche ai file mostrano prima il cambiamento come diff, mantengono ogni altro server e impostazione, salvano una copia accanto
al file (`<file>.cocaine-backup`), e premere *Collega* due volte non cambia nulla. Poi riavvia lo strumento. *Copia* mette sugli
appunti il comando o la voce, se preferisci configurarlo tu.

Si può collegare solo una copia di Cocaine installata in Applicazioni: gli strumenti avviano
`Cocaine.app/Contents/MacOS/Cocaine --mcp` dal suo percorso, che resta lo stesso negli aggiornamenti. Apri Cocaine una volta prima di
collegare (Gatekeeper deve averlo consentito).

## Cosa vede lo strumento AI

Strumenti (tutti in sola lettura):

| Strumento | Argomenti | Risultato |
|---|---|---|
| `context_list` | nessuno | gli elementi: id, tipo, titolo, dimensione |
| `context_get` | `id`, `offset` (facoltativo) | il contenuto di un elemento: testo, il testo di un file, il testo riconosciuto in un'immagine, o i metadati |
| `boards_list` | nessuno | le bacheche condivise con l'AI |
| `board_get` | `board` (nome o id), `cursor` (facoltativo) | gli elementi di una bacheca condivisa |
| `cocaine_request` | `reason` (≤ 500 caratteri), `kinds` (`clipboard`, `shelf`) | ciò che scegli nella notch, o "rifiutato" |
| `cocaine_status` | nessuno | se Cocaine è aperto con il contesto AI attivo |

Inoltre le **risorse** `cocaine://context/<id>` (in Claude Code: `@cocaine:cocaine://context/…`) e il **prompt** `use_context`
(`/mcp__cocaine__use_context`). Codex documenta solo gli strumenti.

Cosa restituisce un elemento:
- testo (scritto, appunti, scaffale): il testo;
- un file di testo (codice, Markdown, JSON, log…, o qualsiasi file UTF-8): i primi 512 KB;
- un PDF: il testo delle prime 20 pagine;
- un'immagine: il testo riconosciuto (su questo Mac) e le dimensioni; **mai i pixel**;
- una cartella o qualsiasi altro file: solo nome, dimensione, tipo e data.

**Limiti**: ogni risposta resta sotto circa 20.000 token (Claude Code si ferma a 25.000 di serie); un elemento più lungo dice da
dove continuare (`offset`, `cursor`). Una domanda nella notch aspetta al massimo 45 secondi (Codex interrompe una chiamata dopo 60).
Al massimo 60 chiamate al minuto per strumento e 4 `cocaine_request` al minuto.

## Consenso

La prima volta che uno strumento chiede, la notch mostra *Consentire a &lt;strumento&gt; di leggere il tuo contesto AI?* con:
- **Consenti**: ricordato per quello strumento;
- **Consenti una volta**: solo per quella sessione dello strumento (fino al suo riavvio, al massimo 8 ore);
- **Nega**: ricordato; non viene chiesto di nuovo;
- **Non ora** (o Esc, o nessuna risposta in 40 secondi): non si ricorda nulla.

Uno strumento è riconosciuto dal nome che dichiara e dal programma che ha avviato il ponte di Cocaine (per esempio `claude`,
`codex`, Claude.app). Impostazioni → AI → *Strumenti AI* elenca le decisioni con *Revoca*.

## Il registro delle attività

Impostazioni → AI → *Attività*: quando, quale strumento, che tipo di richiesta (list, get, board, request), l'esito e quanti
elementi e byte. **Mai il contenuto, i titoli o i percorsi.** Tenuto in `mcp-audit.log` (0600) nella cartella di Cocaine, al massimo
256 KB; *Svuota* lo elimina.

## Come funziona, e il modello delle minacce

`Cocaine --mcp` è un piccolo server MCP **stdio** che lo strumento AI avvia. Parla entrambe le generazioni del protocollo in uso: la
stretta di mano `initialize` (2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05) e la revisione senza stato 2026-07-28
(`server/discover`). È solo un ponte: per ogni chiamata apre il socket privato di Cocaine, risponde, e sull'uscita scrive solo
messaggi MCP. Non tocca da sé gli appunti, il Portachiavi né i tuoi file, e termina quando lo strumento lo chiude.

- **Nessuna porta di rete.** Il ponte parla con l'app tramite un socket Unix (`mcp.sock`) nella cartella privata di Cocaine (0700),
  il socket 0600, solo dallo stesso utente macOS (`getpeereid`), ed entrambe le parti dimostrano di avere una chiave dell'installazione
  (`mcp.key`, 0600, HMAC su nonce nuovi). Il socket esiste solo con l'interruttore attivo. Niente ascolta su TCP, quindi nessun sito
  web può raggiungerlo.
- **Altri tuoi programmi.** Un malware che gira con il tuo utente può leggere quella chiave, come ogni tuo file. A proteggere i dati
  resta il resto: si può leggere solo il contesto AI, ogni strumento va consentito nella notch, e il registro mostra ogni lettura.
  Nome e programma di uno strumento sono etichette, non prove d'identità.
- **Prompt injection.** Il testo copiato può contenere istruzioni rivolte a un'AI. Il contenuto torna sempre tra i segni
  `<<<BEGIN COCAINE USER DATA (untrusted…)>>>` e `<<<END COCAINE USER DATA>>>`, il server dice allo strumento di trattarlo come dati,
  le descrizioni degli strumenti non contengono mai nulla di tuo, il motivo dell'AI mostrato nella notch è ripulito (niente caratteri
  di controllo o che cambiano la direzione del testo, al massimo 120 caratteri), e non ci sono strumenti di scrittura. Comunque uno
  strumento AI può essere ingannato da ciò che legge: metti nel contesto AI solo ciò che incolleresti tu in quello strumento.
- **Uscita dal Mac.** Cocaine non invia nulla da nessuna parte. Ciò che uno strumento legge va al suo fornitore AI, come se l'avessi
  incollato nella chat: è ciò che dice la domanda di consenso.
- **Limitato.** Messaggi oltre 4 MB vengono rifiutati, le risposte hanno un tetto, contesto e registro hanno limiti fissi.

## Limiti

- La scelta nella notch offre quattro elementi alla volta (nell'isola non c'è spazio per altri); metti gli altri nel contesto AI
  dalla notch, e lo strumento li legge con `context_list`.
- Le immagini sono condivise solo come testo riconosciuto e dimensioni.
- Quale versione del protocollo usa ogni strumento, e se mostra risorse e prompt, dipende dallo strumento (Codex: solo strumenti).
  Il test con un client finto verifica entrambe le generazioni; gli strumenti reali non sono stati provati dai test di Cocaine.
- Per collegare Claude Code serve il suo comando `claude`; senza, copia il comando mostrato.

# Movimento

Ogni animazione di Cocaine nasce da un unico sistema in `Sources/Motion.swift`: pochi token, una tabella che assegna a ogni tipo
di cambiamento (un *ruolo*) una curva, e piccoli helper di vista costruiti sopra. Test: `--motion-test` (anche dentro `--selftest`).

## Token

| Token | Valore | Usato per |
|---|---|---|
| `Duration.instant` | 0,08 s | feedback di pressione con Riduci movimento, cambi di simbolo |
| `Duration.quick` | 0,15 s | hover, ogni dissolvenza con Riduci movimento, cambi di etichetta dell'HUD, il pannello che si ridimensiona |
| `Duration.standard` | 0,22 s | dissolvenze di contenuto (cambio lingua, etichetta occupata) |
| `Duration.slow` | 0,4 s | l'avviso a schermo intero che svanisce |
| molla `snappy` | risposta 0,24, smorzamento 0,86 | pressione, selezione, valori, la barra dell'HUD |
| molla `smooth` | risposta 0,32, smorzamento 0,88 | pagine, righe che si espandono, menu a tendina, chiusura dell'isola, ali, risalita dell'HUD, fine di un trascinamento |
| molla `gentle` | risposta 0,42, smorzamento 0,92 | dialoghi, notifiche, schede di richiesta, ciò che arriva |
| molla `bouncy` | risposta 0,36, smorzamento 0,80 | apertura dell'isola, discesa dell'HUD, il pomello dell'interruttore |
| `stagger` | 0,035 s per elemento, al massimo 0,2 s | elementi che arrivano insieme |
| Distanze | pressione 0,97 (glifi 0,92), entrata 8 pt + scala 0,97, pagina 16 pt, sollevamento 1,02 + ombra 8 pt, impulso 1,12 | |
| `islandSettle` | 0,5 s | quando la finestra dell'isola si rimpicciolisce dopo la chiusura (dopo che la molla si è fermata) |
| Versamento | 1,4 s riempimento (ease-out), 0,7 s svuotamento (ease-in) | la bustina nella barra dei menu |

## Ruoli

`Motion.animation(.ruolo)` dà l'animazione di un ruolo; `Motion.with(.ruolo) { … }` esegue un cambiamento del modello con essa.

| Ruolo | Normale | Riduci movimento |
|---|---|---|
| press | snappy | dissolvenza 0,08 s (si scurisce invece di rimpicciolire) |
| hover | ease-out 0,15 s | uguale |
| selection | snappy | dissolvenza 0,15 s |
| toggle | bouncy | subito |
| value, hudBar | snappy | subito |
| expand, dragSettle, wing, islandClose | smooth | subito |
| page, dropdown | smooth | dissolvenza 0,15 s |
| appear, dialog, notice | gentle | dissolvenza 0,15 s |
| islandOpen, hudDrop | bouncy | subito (isola); dissolvenza 0,15 s (HUD) |
| hudRetract | smooth | dissolvenza 0,15 s |
| crossfade | 0,22 s | 0,15 s |
| hudSwap | 0,15 s | 0,08 s |

## Helper

- `.pressable(pressed)`: feedback di pressione (`CocaineButtonStyle`, l'interruttore, `MotionGlyphStyle` per pulsanti a glifo, stepper, righe).
- `.motionAppear(edge:)` / `Motion.appear`: arriva da un bordo, un po' più piccolo, diventando opaco presto (dialoghi, menu a
  tendina, schede di richiesta, file sullo scaffale, righe dell'editor delle schermate).
- `Motion.page(direction)`: la nuova pagina entra dal lato della scheda scelta, la vecchia esce dall'altro, con dissolvenza
  (schermate dell'isola, schede del pannello). `PageDirection` è aggiornata dal modello quando cambia la scheda.
- `.motionSelection(value)`, `.motionNumber(value)` (cifre che scorrono), `.motionPulse(trigger)`, `.motionLift(lifted)`.
- `.shimmer(active)` e `BusyDots`: caricamento, calmo, solo opacità (fotocamera che parte, utilizzo ancora in conteggio,
  aggiornamenti, pulsanti occupati).
- `StripHighlight`: l'evidenziazione delle schede nelle strisce, con il suo hover.

## Regole per una nuova animazione

1. Il modello è l'unica verità. Si anima un suo cambiamento (`Motion.with`, `.motion(_:value:)`), mai con un timer o una catena
   di `asyncAfter`. Un nuovo cambiamento riorienta la molla in corso: SwiftUI ne conserva la velocità, nulla riparte da capo.
2. Il lavoro differito che un cambiamento successivo può superare porta una `MotionGeneration`: esegue solo l'ultimo.
3. Una transizione interrompibile è funzione di un solo valore di avanzamento (il morph dell'isola, la comparsa della pagina, il
   `reveal` dell'HUD): invertita a metà, prosegue da dove si trova.
4. Scegli un ruolo; aggiungine uno alla tabella (con il suo test) solo se nessuno va bene. Mai durate o molle scritte in una vista.
5. Il movimento non cambia mai il layout: solo offset, scala, opacità, sfocatura.
6. Nessun nuovo timer. I cicli (`shimmer`, `BusyDots`) girano solo mentre qualcosa carica. Il versamento ridisegna solo la bustina.

## Riduci movimento, Riduci trasparenza, render

- Riduci movimento: nulla si sposta, scala o rimbalza. Ciò che solo si muove (morph dell'isola, ali, pomello, barre) cambia
  subito; ciò che arriva compare in dissolvenza in 0,15 s; l'avviso è una sola tinta morbida; la pillola del controllo segmentato
  non scorre; un controllo premuto si scurisce.
- Riduci trasparenza: le velature dietro i dialoghi sono più opache.
- `Motion.disabled` (impostato da ogni render e dai controlli a istantanea): nessuna animazione, i cicli fermi, così le immagini
  non colgono mai una transizione a metà.
- `--render-motion <prefisso> [island page hud dropdown dialog] [--reduce-motion]` disegna ogni transizione a 0, 25, 50, 75 e
  100 % con i modificatori dell'app stessa, per guardare i fotogrammi intermedi.

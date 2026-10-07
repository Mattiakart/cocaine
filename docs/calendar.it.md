# La pagina Calendario dell'isola

Tre viste, scelte con il controllo segmentato nell'intestazione della pagina (Giorno · Settimana · Mese). L'intestazione ha
anche il titolo di ciò che è mostrato, i pulsanti precedente/successivo e *Oggi*.

- **Giorno**: la data grande a sinistra e gli eventi di quel giorno; se oggi è vuoto, mostra le prossime due settimane ("In arrivo").
- **Settimana**: sette colonne dal primo giorno della settimana del Mac (Impostazioni di Sistema → Generali → Lingua e Zona),
  ciascuna con i suoi eventi come etichette compatte nel colore del calendario; gli eventi di tutto il giorno sono colorati.
  La colonna di oggi è bordata nel colore d'accento. Clic sull'intestazione di un giorno: lo apre.
- **Mese**: la griglia (nomi dei giorni nella lingua dell'app, giorni degli altri mesi attenuati, oggi nel colore d'accento,
  fino a tre puntini per giorno nei colori dei calendari e "+n" per gli altri) e, accanto, gli eventi del giorno scelto. Clic
  su un giorno per sceglierlo, di nuovo (o Invio) per aprirlo nella vista Giorno. Nelle zone che usano i numeri di settimana
  (Germania, paesi nordici, Paesi Bassi…) c'è la colonna dei numeri di settimana.

Clic su un evento per i dettagli: data e ora (o *Tutto il giorno*, con le date se dura più giorni), il calendario, il luogo,
l'organizzatore e il numero di partecipanti, l'inizio delle note, il link della videochiamata (Zoom, Meet, Teams, Webex…, solo
link http(s): si apre nel browser) e **Apri in Calendario**. Indietro (o Esc) torna alla vista.

**Apri in Calendario** usa il link di Calendario `ical://ekevent/<id>?method=show&options=more`, che non richiede permessi.
Aprire Calendario *a una data* senza evento richiederebbe AppleScript e il permesso Automazione, quindi non si fa.

## Tasti

Con l'isola aperta dalla tastiera (⌃⌥⌘I) e la pagina Calendario mostrata: ←/→ giorno o settimana precedente/successiva (nel
Mese: il giorno, anche tra mesi), ↑/↓ nel Mese una settimana, Pag su/giù l'intervallo precedente/successivo, Inizio o T oggi,
Invio nel Mese apre il giorno, Esc chiude i dettagli (altrimenti l'isola). Sulle altre pagine ←/→ cambiano scheda.

## Dati

- Gli eventi si leggono con EventKit (accesso completo), fuori dal thread principale, per l'intervallo mostrato (la settimana
  per Giorno e Settimana, l'intera griglia per Mese), in cache (al massimo 12 intervalli) con quelli accanto letti in anticipo.
  Un cambiamento nei calendari, un nuovo giorno, un cambio di fuso o di zona svuotano la cache.
- Gli eventi ricorrenti arrivano già espansi da EventKit.
- Un evento sta in ogni giorno che copre; i giorni si contano sull'orologio locale, quindi i giorni dell'ora legale (23 o 25
  ore) e i cambi di fuso orario mettono gli eventi nel giorno giusto.
- **Eventi rifiutati**: mostrati attenuati e barrati, con "Rifiutato", e non contati (niente puntino, non in "3 eventi").

## Movimento e accessibilità

Cambiando intervallo il contenuto entra scorrendo dal lato da cui viene; cambiando vista fa zoom dal giorno scelto; la
selezione si sposta; *Oggi* fa pulsare il segno di oggi. Tutto è guidato da un solo stato (vista e giorno scelto): tocchi
ripetuti in fretta finiscono sempre sull'intervallo giusto. Con Riduci movimento il contenuto appare solo in dissolvenza.
VoiceOver: ogni giorno della griglia è un pulsante come "martedì 7 ottobre, 3 eventi"; i cambi di vista e intervallo sono annunciati.

Test e render: `Cocaine --calendar-test`; `Cocaine --render-island out.png --open --tab calendar --calendar-view month --lang it`
(eventi di esempio, mai il tuo calendario).

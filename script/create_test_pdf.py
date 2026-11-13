#!/usr/bin/env python3
"""Reproducible monochrome A4 scanner fixture; no personal data."""
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph
from reportlab.lib.styles import ParagraphStyle
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/pdf/CanonScan-Scannertest-4-Seiten.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
FONTS = Path('/System/Library/Fonts/Supplemental')
for name, filename in [('Body', 'Arial.ttf'), ('Strong', 'Arial Bold.ttf'), ('Mono', 'Courier New.ttf')]:
    pdfmetrics.registerFont(TTFont(name, str(FONTS / filename)))
W, H = A4
M = 18*mm
c = canvas.Canvas(str(OUT), pagesize=A4, pageCompression=1)
c.setTitle('CanonScan - vierseitiger Schwarzweiss-Scannertest')
c.setAuthor('CanonScan')
c.setSubject('Testvorlage für ADF, Duplex, Seitenfolge, Bildqualität und lokale OCR')

def text(x, y, value, size=11, font='Body', gray=0):
    c.setFillGray(gray); c.setFont(font, size); c.drawString(x, y, value)

def para(y, value, size=11, leading=None):
    p = Paragraph(value, ParagraphStyle('Body', fontName='Body', fontSize=size,
                  leading=leading or size*1.5, textColor='#000000'))
    _, height = p.wrap(W-2*M, H)
    p.drawOn(c, M, y-height)
    return y-height-7*mm

def section(y, title):
    text(M, y, title, 13, 'Strong'); return y-8*mm

def header(number, title, sheet, side, token):
    c.setStrokeGray(.3); c.setLineWidth(.5)
    c.rect(12*mm, 12*mm, W-24*mm, H-24*mm)
    # Registration marks sit safely inside ordinary laser printer margins.
    for x in [12*mm, W-12*mm]:
        for y in [12*mm, H-12*mm]:
            c.line(x-2*mm, y, x+2*mm, y); c.line(x, y-2*mm, x, y+2*mm)
    text(M, H-24*mm, 'CANONSCAN  /  SCHWARZWEISS-TEST', 9, 'Strong', .25)
    text(W-43*mm, H-24*mm, f'{number:02d} / 04', 14, 'Strong')
    text(M, H-41*mm, title, 24, 'Strong')
    text(M, H-50*mm, f'Blatt {sheet} - {side}  |  Oberkante oben', 11)
    c.line(M, H-56*mm, W-M, H-56*mm)
    text(M, 23*mm, token, 10, 'Mono')
    text(M, 17*mm, f'Erwartete PDF-Position: Seite {number} von 4', 8, gray=.25)
    return H-67*mm

y = header(1, 'Einzug & Lesbarkeit', 1, 'Vorderseite', 'CANONSCAN SEITE 01 ALPHA 4827')
y = section(y, 'So wird die Vorlage verwendet')
y = para(y, 'Alle vier Seiten auf A4 bei <b>100 % / Originalgröße</b> drucken. '
         'Wenn möglich: <b>beidseitig, an der langen Kante wenden</b>. Das ergibt zwei Blätter. '
         'Ohne Duplexdruck bitte vier einzelne Blätter drucken; dann prüfen wir den Einzug zunächst einseitig.', 10)
y = section(y, 'Lesetext - 12 Punkt')
y = para(y, 'Im Frühjahr öffnet die kleine Bücherei ihre Türen schon um acht Uhr. '
         'Auf dem grünen Tisch liegen zwölf Briefe, fünf Quittungen und ein sorgfältig gefalteter Plan. '
         'Herr Weiß prüft die Unterlagen, während Frau Müller die nächsten Schritte erklärt. '
         'Jede Seite soll vollständig, scharf und in der richtigen Reihenfolge erhalten bleiben.', 12)
y = section(y, 'Umlaute, Sonderzeichen und Zahlen')
for line in ['Ä Ö Ü ä ö ü ß - Straße, Größe, Prüfung, äußere Ränder',
             'Betrag: 1.234,56 EUR   Datum: 13.11.2026   Uhrzeit: 08:45',
             'Telefon: 030 12345678   E-Mail: scanner@example.test',
             'Referenz: AB-2026-04827   Zeichen: ( ) [ ] / + = % &']:
    text(M, y, line, 10); y -= 7*mm
y -= 7*mm
y = para(y, '<b>Duplex-Kontrolle:</b> Die Rückseite dieses Blatts trägt die große Nummer 02. '
         'Die Seiten 01 und 02 gehören zusammen. Bitte nichts abschneiden oder nachträglich beschriften.', 10)
c.showPage()

y = header(2, 'Duplex & Zahlen', 1, 'Rückseite', 'CANONSCAN SEITE 02 BRAVO 5938')
y = section(y, 'Lesetext - 11 Punkt')
y = para(y, 'Dies ist die Rückseite des ersten Blatts. Beim beidseitigen Scannen muss sie direkt '
         'nach Seite 01 erscheinen. Der Text darf weder auf dem Kopf stehen noch spiegelverkehrt sein. '
         'Die feinen Buchstaben in diesem Absatz helfen dabei, die Qualität der zweiten Scanzeile '
         'mit der Vorderseite zu vergleichen. Auch am linken und rechten Rand dürfen keine Wörter fehlen.', 11)
y = section(y, 'Fiktive Abrechnung - keine echten Geschäftsdaten')
rows = [ ['Position', 'Anzahl', 'Einzelpreis', 'Gesamt'],
        ['Ordner schmal', '3', '4,50 EUR', '13,50 EUR'],
        ['Papier A4, 500 Blatt', '2', '6,25 EUR', '12,50 EUR'],
        ['Briefumschläge', '1', '8,90 EUR', '8,90 EUR'],
        ['Summe', '', '', '34,90 EUR'] ]
colx = [M+3*mm, M+80*mm, M+105*mm, M+139*mm]
rowh=12*mm
for ri, row in enumerate(rows):
    if ri == 0:
        c.setFillGray(.9); c.rect(M, y-rowh+3*mm, W-2*M, rowh, fill=1, stroke=0)
    for x, value in zip(colx,row): text(x,y-5*mm,value,10,'Strong' if ri in [0,4] else 'Body')
    c.setStrokeGray(.6); c.setLineWidth(.35); c.line(M,y-rowh+3*mm,W-M,y-rowh+3*mm)
    y-=rowh
y-=12*mm
y = section(y, 'Ähnliche Zeichen - bewusst getrennt')
for line in ['Ziffer Null: 0 0 0   /   Buchstabe O: O O O',
             'Ziffer Eins: 1 1 1   /   großes I: I I I   /   kleines l: l l l',
             'Code: B8-S5-Z2-G6   Nummer: 0123456789',
             'Eindeutiger Suchsatz: Der flinke Fuchs findet fünf frische Feigen.']:
    text(M,y,line,10);y-=8*mm
y-=6*mm
para(y,'<b>Erwartung:</b> Die Tabelle bleibt gerade, die Beträge sind lesbar und der Suchsatz '
        'lässt sich nach dem OCR-Export im PDF finden. Einzelne OCR-Verwechslungen sind gesondert zu prüfen.',10)
c.showPage()

y = header(3, 'Schärfe & Schriftgrößen', 2, 'Vorderseite', 'CANONSCAN SEITE 03 CHARLIE 6049')
y = section(y, 'Derselbe Satz in unterschiedlichen Größen')
for size in [16,12,10,9,8,6]:
    text(M,y,f'{size} pt',9,'Mono',.25)
    text(M+19*mm,y,'Fünf große Vögel fliegen über die Straße.',size)
    y-=max(11*mm,size*1.7)
y-=5*mm
y = section(y, 'Feine Linien - vergleichen, nicht als Messgerät verwenden')
for thickness in [.25,.5,.75,1.0]:
    text(M,y,f'{thickness:g} pt',9,'Mono')
    c.setStrokeGray(0);c.setLineWidth(thickness);c.line(M+22*mm,y+1*mm,W-M,y+1*mm)
    y-=9*mm
y-=8*mm
y = section(y, 'Kleiner Text - 9 Punkt')
y = para(y,'Die Qualität hängt von Drucker, Papier, Einzug und Scanauflösung ab. '
         'Ein klarer Druck ist die Voraussetzung für einen aussagekräftigen Vergleich. '
         'Bei 300 dpi sollten normale Briefe gut lesbar sein. 600 dpi kann kleine Schrift '
         'besser erfassen, benötigt aber mehr Zeit und Speicherplatz. Die sechs Punkt große '
         'Zeile ist ein Härtetest und kein Muss für einen guten Dokumentenscan.',9,14)
text(M,y,'Muster: ABCDEFGHIJKLMNOPQRSTUVWXYZ',11,'Mono');y-=7*mm
text(M,y,'Muster: abcdefghijklmnopqrstuvwxyz 0123456789',10,'Mono')
c.showPage()

y = header(4, 'Graustufen & Abschluss', 2, 'Rückseite', 'CANONSCAN SEITE 04 DELTA 7150')
y = section(y, 'Neun Graufelder - von Weiß bis Schwarz')
cell=(W-2*M)/9
for i in range(9):
    c.setFillGray(1-i/8);c.setStrokeGray(.45);c.setLineWidth(.3)
    c.rect(M+i*cell,y-20*mm,cell,20*mm,stroke=1,fill=1)
    text(M+i*cell+3*mm,y-26*mm,f'{round(i/8*100)} %',8,'Mono')
y-=39*mm
y = para(y,'Ein Schwarzweiß-Laserdrucker bildet Grau mit Rasterpunkten nach. '
         'Diese Felder dienen deshalb nur zum Vergleich des gedruckten Originals mit dem Scan. '
         'Im Graustufen-Scan sollten möglichst viele Felder unterscheidbar bleiben. '
         'Im reinen Schwarzweiß-Modus gehen Abstufungen erwartungsgemäß verloren.',10)
y = section(y, 'Schwacher Text')
for darkness,label in [(.35,'35 % Schwarz'),(.55,'55 % Schwarz'),(1.0,'100 % Schwarz')]:
    text(M,y,f'{label}: Dieser Satz prüft blasse Vorlagen und zarte Linien.',10,gray=1-darkness)
    y-=8*mm
y-=9*mm
y=section(y,'Abschließender Lesetext - 12 Punkt')
y=para(y,'Am Ende werden alle vier Seiten als ein einziges Dokument gespeichert. '
       'Die Bilder sollen dem Papier entsprechen, während eine unsichtbare Textebene das Suchen '
       'und Kopieren ermöglicht. Die Scanner-App verarbeitet die Dokumente lokal auf dem Mac. '
       'Damit ist der Test vollständig: ALPHA, BRAVO, CHARLIE und DELTA stehen in dieser Reihenfolge.',12)
para(y,'<b>Ergebnis prüfen:</b> vier Seiten, korrekte Reihenfolge, lesbare Ränder, keine auffälligen Streifen '
       'und keine fehlende Rückseite. Danach nach <b>CHARLIE 6049</b> suchen und einen Absatz kopieren.',10)
c.showPage()
c.save()
reader=PdfReader(OUT)
assert len(reader.pages)==4
for i,page in enumerate(reader.pages,1):
    assert f'SEITE {i:02}' in page.extract_text()
    assert abs(float(page.mediabox.width)-W)<.01
    assert abs(float(page.mediabox.height)-H)<.01
print(OUT)

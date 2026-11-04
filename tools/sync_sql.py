"""Sincroniza un archivo supabase/<nombre>.sql con su bloque dentro de supabase/schema.sql (lo agrega al final si no existe; si existe, lo reemplaza SIN tocar los demás bloques)."""
import sys, re
name = sys.argv[1]
blk = open('supabase/' + name, encoding='utf-8').read().strip()
s = open('supabase/schema.sql', encoding='utf-8').read()
head = '\n'.join(blk.split('\n')[:2])          # "-- ====" + "-- Bastet · ..."
i = s.find(head)
if i == -1:
    s = s.rstrip('\n') + '\n\n' + blk + '\n'
else:
    m = re.search(r'\n-- =====================================================================\n-- Bastet · ', s[i + len(head):])
    j = i + len(head) + m.start() + 1 if m else len(s)
    s = s[:i] + blk + '\n' + (('\n' + s[j:]) if m else '')
open('supabase/schema.sql', 'w', encoding='utf-8', newline='').write(s.rstrip('\n') + '\n')
print('sincronizado', name, 'bloque nuevo' if i == -1 else 'bloque reemplazado')

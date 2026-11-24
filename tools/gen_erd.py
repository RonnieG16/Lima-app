# Regenerates the "ERD (as built)" page in docs/LIMA_DESIGNS.drawio from supabase/schema.sql. Run from the lima/ folder: python3 tools/gen_erd.py
import re
from xml.sax.saxutils import quoteattr
sql=open('supabase/schema.sql').read(); tabs={}
for m in re.finditer(r'create table if not exists (\w+) \((.*?)\n\);',sql,re.S):
    body=re.sub(r'--[^\n]*','',m.group(2)); parts=[];d=0;cur=''
    for ch in body:
        d+=(ch=='(')-(ch==')')
        if ch==',' and d==0: parts.append(cur);cur=''
        else: cur+=ch
    parts.append(cur); cols=[];fks=[];pkc=set()
    for p in parts:
        p=' '.join(p.split())
        mm=re.match(r'primary key \((.*)\)',p)
        if mm: pkc|={x.strip() for x in mm.group(1).split(',')}; continue
        cm=re.match(r'(\w+) (uuid|text|numeric\(\d+,\d+\)|numeric|smallint|boolean|date|timestamptz|bigint|integer)',p)
        if not p or p.startswith('unique') or not cm: continue
        ref=re.search(r'references (\w+)\(',p)
        if ref: fks.append(ref.group(1))
        cols.append([cm.group(1),cm.group(2).replace('timestamptz','timestamp'),'primary key' in p or 'generated always' in p,bool(ref)])
    for c in cols:
        if c[0] in pkc: c[2]=True
    tabs[m.group(1)]=(cols,fks)
order=['profiles','listings','orders','payments','deliveries','ratings','disputes','market_prices','audit_log','cart_items','wishlist','notifications','messages','site_settings','feedback','sms_outbox']
new={'cart_items','wishlist','notifications','messages','site_settings','feedback','sms_outbox'}
ROW=22;W=250;colx=[40,340,640,940];coly=[40]*4;cells=[];n=0
for i,t in enumerate(order):
    cols,fks=tabs[t];c=i%4;x,y=colx[c],coly[c];h=28+ROW*len(cols)
    st='swimlane;fontStyle=1;childLayout=stackLayout;horizontal=1;startSize=28;horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=0;marginBottom=0;fontSize=13;swimlaneFillColor=#ffffff;'+('fillColor=#d5e8d4;strokeColor=#82b366;' if t in new else '')
    cells.append(f'<mxCell id="asb_{t}" parent="1" style="{st}" value={quoteattr(t.upper()+(" (was USER)" if t=="profiles" else ""))} vertex="1"><mxGeometry x="{x}" y="{y}" width="{W}" height="{h}" as="geometry"/></mxCell>')
    for j,(cn,ct,pk,fk) in enumerate(cols):
        tag='PK,FK' if pk and fk else 'PK' if pk else 'FK' if fk else ''
        cells.append(f'<mxCell id="asb_{t}_r{j}" parent="asb_{t}" style="text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;spacingLeft=6;fontSize=11;{"fontStyle=1;" if pk else ""}overflow=hidden;" value={quoteattr((tag+"  " if tag else "      ")+cn+" : "+ct)} vertex="1"><mxGeometry y="{28+ROW*j}" width="{W}" height="{ROW}" as="geometry"/></mxCell>')
    coly[c]=y+h+40
for t in order:
    for ref in tabs[t][1]:
        if ref in order and ref!=t:
            n+=1; cells.append(f'<mxCell id="asb_e{n}" edge="1" parent="1" source="asb_{ref}" target="asb_{t}" style="edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=ERmany;startArrow=ERmandOne;strokeColor=#888888;"><mxGeometry relative="1" as="geometry"/></mxCell>')
note='ERD as built in Supabase (supabase/schema.sql). Green = tables added after the original ERD. IDs are uuid. Lines run from parent (one) to child (many); the layout is generated, so tidy it in draw.io.'
cells.append(f'<mxCell id="asb_note" parent="1" style="text;html=1;whiteSpace=wrap;fontSize=12;fontStyle=2;" value={quoteattr(note)} vertex="1"><mxGeometry x="40" y="-10" width="900" height="40" as="geometry"/></mxCell>')
page='<diagram name="ERD (as built)" id="asbuilt-erd"><mxGraphModel grid="1" page="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" pageScale="1" pageWidth="1400" pageHeight="1400" math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>'+''.join(cells)+'</root></mxGraphModel></diagram>'
f='docs/LIMA_DESIGNS.drawio';s=open(f).read()
s=re.sub(r'<diagram name="ERD \(as built\)".*?</diagram>\s*','',s,flags=re.S)
s=s.replace('</mxfile>',page+'\n</mxfile>');open(f,'w').write(s)
import xml.dom.minidom as md; md.parseString(s); print('ok',len(order),'tables')

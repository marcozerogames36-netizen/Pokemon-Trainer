# Publicar na Vercel

O jogo é um site estático: `index.html` usa os arquivos de `assets/` e não precisa de etapa de build. O Supabase continua sendo o serviço de autenticação e salvamento.

## Publicação pelo painel da Vercel

1. Envie `index.html`, `assets/` e `supabase-schema.sql` para um repositório GitHub.
2. Na Vercel, escolha **Add New → Project** e importe esse repositório.
3. Configure **Framework Preset: Other**, deixe **Build Command** vazio e use `.` como **Output Directory**. A raiz do projeto deve conter `index.html`.
4. Clique em **Deploy**. Primeiro use o endereço de Preview gerado para conferir o jogo.

Também é possível publicar pelo terminal, na pasta do projeto, com `npx vercel`; para publicar em produção depois de vincular a conta, use `npx vercel --prod`.

## Configurar o Supabase depois do primeiro deploy

No Supabase, abra **Authentication → URL Configuration**:

1. Defina **Site URL** como o endereço de produção, por exemplo `https://seu-jogo.vercel.app`.
2. Em **Redirect URLs**, adicione o endereço exato de produção, por exemplo `https://seu-jogo.vercel.app/**`.
3. Se usar URLs de Preview, adicione o padrão da sua equipe Vercel, por exemplo `https://*-sua-equipe.vercel.app/**`.
4. Salve e teste cadastro/confirmação de e-mail, login, recuperação de senha e carregamento do save.

O jogo já passa a URL atual como destino dos fluxos de cadastro, login social e recuperação de senha. Por isso, cada domínio usado precisa estar permitido na lista de redirecionamentos do Supabase.

## Observações

- A chave `sb_publishable_...` no HTML é uma chave pública de cliente; não coloque uma chave `sb_secret_...` ou `service_role` no navegador.
- O arquivo `supabase-schema.sql` documenta a tabela e as políticas RLS. Ele não configura o banco automaticamente; aplique-o no SQL Editor do Supabase se ainda não tiver sido aplicado.
- Após publicar, faça um save, atualize a página e confirme que o progresso voltou.

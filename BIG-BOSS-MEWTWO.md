# Big Boss: Mewtwo

## Ativar no Supabase

1. Abra o projeto no Supabase e acesse **SQL Editor**.
2. Selecione todo o conteúdo de `cooperative-boss-migration.sql` e execute.
3. Publique o site atualizado na Vercel.

A migration deve ser aplicada depois de `supabase-schema.sql`, pois reutiliza os validadores e a tabela de tipos do sistema PvP. Ela cria uma tabela própria para as raids, com RLS e operações protegidas por RPC; não dá acesso direto de escrita aos saves.

## Como jogar

- Abra **Big Boss: Mewtwo** no acesso rápido.
- O anfitrião cria uma sala e compartilha o código de seis caracteres.
- Até cinco contas diferentes entram com suas equipes; o anfitrião inicia a luta.
- Cada participante escolhe uma ação por rodada. Quando todos agem, Mewtwo ataca cada equipe que ainda tem Pokémon conscientes.
- Mewtwo começa com 30.000 HP compartilhados. Rodadas sem ação são liberadas após 90 segundos quando algum participante envia a próxima ação.
- HP e PP da raid são temporários e não alteram os Pokémon salvos. Não há recompensa nesta primeira versão.

Se um participante atualizar a página durante a batalha, pode voltar ao Big Boss e entrar novamente com o mesmo código para retomar a sala.

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { BrowserRouter, NavLink, Route, Routes } from 'react-router-dom';
import { CAPACITY_ADDRESS, PRICER_ADDRESS, TREATY_ADDRESS, USDG_ADDRESS } from './abi';
import { explorer, wagmiConfig } from './chain';
import { Wallet } from './components/Wallet';
import { Overview } from './pages/Overview';
import { Bind } from './pages/Bind';
import { Write } from './pages/Write';
import { short } from './lib/format';

const queryClient = new QueryClient();

export function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <header className="nav">
            <NavLink to="/" className="logo" aria-label="Heracles, SPY weekend cover">
              <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="3" width="5" height="18" rx="1" /><rect x="16" y="3" width="5" height="18" rx="1" /><rect className="t" x="8" y="10" width="8" height="4" /></svg>
              Heracles
            </NavLink>
            <details className="routes" onClick={(e) => { if ((e.target as HTMLElement).closest('a')) e.currentTarget.open = false; }}>
              <summary aria-label="Sections"><svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 4.5 6 8.5l4-4" /></svg></summary>
              <nav aria-label="Sections">
                <NavLink to="/" end>Cover</NavLink>
                <NavLink to="/bind">Exact terms</NavLink>
                <NavLink to="/write">Write cover</NavLink>
              </nav>
            </details>
            <nav className="pills" aria-label="Sections">
              <NavLink to="/" end>Cover</NavLink>
              <NavLink to="/bind">Exact terms</NavLink>
              <NavLink to="/write">Write cover</NavLink>
            </nav>
            <Wallet />
          </header>
          <main className="shell">
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/bind" element={<Bind />} />
              <Route path="/write" element={<Write />} />
            </Routes>
          </main>
          <footer className="foot">
            <p>Heracles: parametric cover for the weekend gap, for the LP vaults of stock perp exchanges. Arbitrum Sepolia testnet, USDG.</p>
            <p>
              Treaty <a href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a>
              {' · '}capacity <a href={explorer.address(CAPACITY_ADDRESS)} target="_blank" rel="noreferrer">{short(CAPACITY_ADDRESS)}</a>
              {' · '}pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>
              {' · '}USDG <a href={explorer.address(USDG_ADDRESS)} target="_blank" rel="noreferrer">{short(USDG_ADDRESS)}</a>
            </p>
          </footer>
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

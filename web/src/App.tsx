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
          <header className="top">
            <div className="wrap top-in">
              <NavLink to="/" className="mark" aria-label="Heracles, weekend gaps">Heracles</NavLink>
              <nav aria-label="Sections">
                <NavLink to="/" end>Weekend gaps</NavLink>
                <NavLink to="/bind">Price cover</NavLink>
                <NavLink to="/write">Earn premium</NavLink>
              </nav>
              <Wallet />
            </div>
          </header>
          <main className="wrap">
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/bind" element={<Bind />} />
              <Route path="/write" element={<Write />} />
            </Routes>
          </main>
          <footer className="wrap">
            <div className="foot">
            <p>Heracles: parametric cover for the weekend gap, for the LP vaults of stock perp exchanges. Arbitrum Sepolia, USDG.</p>
            <p>
              Treaty <a href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a>
              {' · '}capacity <a href={explorer.address(CAPACITY_ADDRESS)} target="_blank" rel="noreferrer">{short(CAPACITY_ADDRESS)}</a>
              {' · '}pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>
              {' · '}USDG <a href={explorer.address(USDG_ADDRESS)} target="_blank" rel="noreferrer">{short(USDG_ADDRESS)}</a>
            </p>
            </div>
          </footer>
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

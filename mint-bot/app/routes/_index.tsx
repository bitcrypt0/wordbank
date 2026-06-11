import type { MetaFunction } from "@remix-run/node";
import Bot from "./Bot";

export const meta: MetaFunction = () => [
  { title: "WORDBANK Mint Bot" },
  { name: "description", content: "Owner-run tool to drive a WordBank sale to the 9,800 sellout for the testnet rehearsal." },
];

export default function Index() {
  return <Bot />;
}

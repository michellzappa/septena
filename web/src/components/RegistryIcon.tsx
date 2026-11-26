import {
  Bot,
  Calendar,
  Check,
  Circle,
  CircleCheck,
  CircleDashed,
  CircleEllipsis,
  CircleStop,
  Clock,
  Eye,
  Layers,
  Mail,
  MessageCircleQuestion,
  MonitorSmartphone,
  Repeat,
  Star,
  Sun,
  type LucideIcon,
  type LucideProps,
} from "lucide-react";
import { ICONS } from "@/lib/generated/registries";

// The lucide icons that registry/icons.json names for the smart lists, their
// groups and the sign-in methods. A named import keeps the rest of lucide out of the bundle.
const LUCIDE: Record<string, LucideIcon> = {
  bot: Bot,
  calendar: Calendar,
  check: Check,
  "circle-check": CircleCheck,
  "circle-dashed": CircleDashed,
  "circle-ellipsis": CircleEllipsis,
  "circle-stop": CircleStop,
  clock: Clock,
  eye: Eye,
  layers: Layers,
  mail: Mail,
  "message-circle-question": MessageCircleQuestion,
  "monitor-smartphone": MonitorSmartphone,
  repeat: Repeat,
  star: Star,
  sun: Sun,
};

const REGISTRY_ICONS: Record<string, { lucide: string } | undefined> = ICONS;

/** The icon of a registry/icons.json token, such as `list.review`. */
export function RegistryIcon({ token, ...props }: { token: string } & LucideProps) {
  const Icon = LUCIDE[REGISTRY_ICONS[token]?.lucide ?? ""] ?? Circle;
  return <Icon {...props} />;
}

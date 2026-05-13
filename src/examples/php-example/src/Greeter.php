<?php

declare(strict_types=1);

namespace PhpExample;

final class Greeter
{
    public function hello(string $stack = 'php-builtin'): array
    {
        return ['hello' => 'from php-example', 'stack' => $stack];
    }
}
